
# save inversion
#function sinv(x::Union{AbstractArray{T},KnetArray{T},AutoGrad.Result{<:AbstractArray{T}}}; minx = T(1e-3)) where T
function sinv(x, ; minx = eltype(x)(1e-3))
    T = eltype(x)
    return one(T) ./ max.(x,minx)
end

# upsampling
struct Upsample{TA,N}
    w::TA
    padding::NTuple{N,Int}
end

function Upsample(sz::Tuple, nvar; atype = Knet.atype(), method = :nearest)
    N = length(sz)
    #nvar = sz[N+1]
    #ksize = (2,2,2)
    # (2,2,...) for as many spatial/temporal dimension there are
    ksize = ntuple(i -> 2, N)
    allst = ntuple(i -> :, N)
    println("size = $sz; nvar = $nvar, ksize = $ksize, method = $method")

    if method == :nearest
        w = atype(zeros(ksize...,nvar,nvar))
        for i = 1:nvar
            w[allst...,i,i] .= 1
        end
    elseif method == :bilinear
        if N !== 2
            error("bilinear work only in 2 dimensions")
        end
        w = atype(bilinear(Float32,2,2,nvar,nvar))
    else
        error("unsupported method $method")
    end

    padding = ntuple(i -> 0, N)
    return Upsample(w,padding)
end
function (m::Upsample)(x)
    y = Knet.deconv4(m.w,x,stride=2,padding = m.padding)
    if size(m.w,2) == 2
        # nearest
        return y
    else
        # bilinear
        return y[2:end-1,2:end-1,:,:]
    end
end

weights(m::Union{Function,Upsample}) = []

function upsample(x)
    N = ndims(x)
    nvar = size(x,N-1)
    #ksize = (2,2,2)
    # (2,2,...) for as many spatial/temporal dimension there are
    ksize = ntuple(i -> 2, N-2)
    allst = ntuple(i -> :, N-2)

    w = similar(x,ksize...,nvar,nvar)
    fill!(w,0)

    for i = 1:nvar
        #w[:,:,:,i,i] .= 1
        w[allst...,i,i] .= 1
    end
    return Knet.deconv4(w,x,stride=2)
end

export upsample

struct CatSkip
    inner
end
export CatSkip

function (m::CatSkip)(x)
#    @show size(x),size(m.inner(x))
    return cat(m.inner(x), x, dims=Val(3))
end
#(m::CatSkip)(x) = x


struct SumSkip
    inner
end
export SumSkip

function (m::SumSkip)(x)
    return m.inner(x) + x
end

weights(m::Union{CatSkip,SumSkip}) = weights(m.inner)

# dense layer
struct Dense
    w
    b
    f
    dropout_rate_train
end

(d::Dense)(x) = dropout(d.f.(d.w * mat(x) .+ d.b),d.dropout_rate_train)
Dense(i::Int,nout::Int,dropout_rate_train::AbstractFloat,f=relu) = Dense(param(nout,i), param0(nout), f, dropout_rate_train)
export Dense

# Define convolutional layer:
struct Conv
    w
    b
    f
end
export Conv

mse(x,y) = mean((x-y).^2)

(c::Conv)(x) = c.f.(conv4(c.w, x, padding = 1) .+ c.b)
# deprecated
Conv(w1::Integer,w2::Integer,cx,cy,f = relu) = Conv(param(w1,w2,cx,cy), param0(1,1,cy,1), f)

Conv(w::NTuple{2},cx,cy,f = relu) = Conv(param(w[1],w[2],cx,cy), param0(1,1,cy,1), f)
Conv(w::NTuple{3},cx,cy,f = relu) = Conv(param(w[1],w[2],w[3],cx,cy), param0(1,1,1,cy,1), f)



# Chain of layers
struct Chain
    layers
end
export Chain

function (c::Chain)(x)
    for l in c.layers
        x = l(x)
    end
    return x
end

weights(m::Chain) = reduce(vcat,weights.(m.layers))


mutable struct BatchNorm
    inputsize
    w
    m
end

(l::BatchNorm)(x; o...) = batchnorm(x, l.m, l.w; o...)

function BatchNorm(; input::Int, atype=Knet.atype())
    w = Param(atype(bnparams(input)))
    m = bnmoments()
    return BatchNorm(input, w, m)
end

BatchNorm(input; kwargs...) = BatchNorm(input=input; kwargs...)


struct ConvBN
    w
    b
    bn
    f
end
export ConvBN

(c::ConvBN)(x) = c.f.(c.bn(conv4(c.w, x, padding = 1) .+ c.b))
ConvBN(w::NTuple{2},cx,cy,f = relu) = ConvBN(param(w[1],w[2],cx,cy), param0(1,1,cy,1), BatchNorm(cy), f)
ConvBN(w::NTuple{3},cx,cy,f = relu) = ConvBN(param(w[1],w[2],w[3],cx,cy), param0(1,1,1,cy,1), BatchNorm(cy), f)


weights(m::Union{Dense,BatchNorm,Conv,ConvBN}) = [m.w]

# Model
struct Model
    chain
    truth_uncertain
    gamma
end
export Model

"""
transform x[:,:,1,:] and x[:,:,2,:] to mean and error variance
"""
function transform_m??2_single(x,gamma)
    N = ndims(x)
    allst = ntuple(i -> :, N-2)

    loginv??2_rec = x[allst...,2:2,:]
    inv??2_rec = exp.(min.(loginv??2_rec,gamma))
    ??2_rec = sinv(inv??2_rec)
    m_rec = x[allst...,1:1,:] .* ??2_rec

    return cat(
       m_rec,
       ??2_rec,
    dims = Val(N-1))
end

function transform_m??2(x,gamma)
    N = ndims(x)
    allst = ntuple(i -> :, N-2)
    noutput = size(x,N-1) ?? 2

    pcat(x,y) = cat(x,y,dims = Val(N-1))

    return reduce(
        pcat,
        (transform_m??2_single(x[allst...,(1:2).+2*ivar,:],gamma) for ivar = 0:noutput-1))
end

weights(model::Model) = weights(model.chain)

function (model::Model)(x_)
    N = ndims(x_)
    pcat(x,y) = cat(x,y,dims = Val(N-1))

    allst = ntuple(i -> :, N-2)

    x = model.chain(x_)

    noutput = 2

    return reduce(
        pcat,
        (transform_m??2(x[allst...,(1:2).+2*ivar,:],model.gamma) for ivar = 0:noutput-1))

end

function costfun_single(xrec,xtrue,truth_uncertain)
    N = ndims(xtrue)
    allst = ntuple(i -> :, N-2)

    m_rec = xrec[allst...,1:1,:]
    ??2_rec = xrec[allst...,2:2,:]

    ??2_true = sinv(xtrue[allst...,2:2,:])
    m_true = xtrue[allst...,1:1,:] .* ??2_true

    # # 1 if measurement
    # # 0 if no measurement (cloud or land for SST)
    mask_noncloud = xtrue[allst...,2:2,:] .!= 0

#    @show extrema(Array(m_rec))
#    @show extrema(Array(m_true))

    n_noncloud = sum(mask_noncloud)
    #@show n_noncloud
    if truth_uncertain
        # KL divergence between two univariate Gaussians p and q
        # p ~ N(??2_1,\mu_1)
        # q ~ N(??2_2,\mu_2)
        #
        # 2 KL(p,q) = log(??2_2/??2_1) + (??2_1 + (??_1 - ??_2)^2)/(??2_2) - 1
        # 2 KL(p,q) = log(??2_2) - log(??2_1) + (??2_1 + (??_1 - ??_2)^2)/(??2_2) - 1
        # 2 KL(p_true,q_rec) = log(??2_rec/??2_true) + (??2_true + (??_rec - ??_true)^2)/(??2_rec) - 1

        # where there is cloud, ??2_ratio is 1 and its log is zero

        ??2_ratio = (??2_rec ./ ??2_true) .* mask_noncloud + (1 .- mask_noncloud)
        #cost = (sum(log.(??2_ratio)) + sum((??2_true + difference.^2) ./ ??2_rec)) / n_noncloud

        ??2_rec_noncloud = ??2_rec .* mask_noncloud + (1 .- mask_noncloud)
        difference2 = ((m_rec - m_true).^2  + ??2_true)  .* mask_noncloud

        #cost = (sum(log.(??2_rec_noncloud)) + sum(difference2 ./ ??2_rec)) / n_noncloud
        cost = (sum(log.(??2_ratio)) + sum(difference2 ./ ??2_rec)) / n_noncloud
    else
        # where there is cloud, ??2_rec_noncloud is 1 and its log is zero
        ??2_rec_noncloud = ??2_rec .* mask_noncloud + (1 .- mask_noncloud)
        difference2 = (m_rec - m_true).^2  .* mask_noncloud

        cost = (sum(log.(??2_rec_noncloud)) + sum(difference2 ./ ??2_rec)) / n_noncloud
    end

    difference2 = (m_rec - m_true).^2  .* mask_noncloud
    costMSE = sum(difference2) / n_noncloud

    #return costMSE
    #    cost = sum(??2_rec .* mask_noncloud)

    return cost
end

# cost function for multivariate output case
function costfun(xrec,xtrue,truth_uncertain)
    N = ndims(xtrue)
    noutput = size(xtrue,N-1) ?? 2

    allst = ntuple(i -> :, N-2)

    # sum over all output parameters
    return sum(
        [
            costfun_single(
                xrec[allst...,(1:2) .+ 2*ivar,:],
                xtrue[allst...,(1:2) .+ 2*ivar,:],
                truth_uncertain
            )
            for ivar in 0:noutput-1 ])
end

function (model::Model)(inputs_,xtrue)
    xrec = model(inputs_)
    return costfun(xrec,xtrue,model.truth_uncertain)
end

# Model
struct StepModel
    chains
    noutput
    loss_weights
    truth_uncertain
    gamma
    regularization_L1
    regularization_L2
end

weights(model::StepModel) = reduce(vcat,weights.(model.chains))

function StepModel(chains,noutput,loss_weights,truth_uncertain,gamma)
    return StepModel(chains,noutput,loss_weights,truth_uncertain,gamma,0.f0,0.f0)
end

function (model::StepModel)(xin)
    xout = model.chains[1](xin)

    for i = 2:length(model.chains)
        xout = model.chains[i](cat(xout[:,:,1:(2*model.noutput),:],xin,dims=3))
    end
    return transform_m??2(xout,model.gamma)
end

function (model::StepModel)(xin,xtrue)
    N = ndims(xin)
    noutput = size(xtrue,N-1) ?? 2
    xout = model.chains[1](xin)

    loss = model.loss_weights[1] *
        costfun(transform_m??2(xout,model.gamma),xtrue,model.truth_uncertain)

    #@show loss
    for i = 2:length(model.chains)
        xout = model.chains[i](cat(xout[:,:,1:(2*noutput),:],xin,dims=3))
        loss += model.loss_weights[i] *
            costfun(transform_m??2(xout,model.gamma),xtrue,model.truth_uncertain)
        #@show loss
    end

    # regularization
    for w in weights(model)
        if model.regularization_L1 !== 0
            #@show i,j,model.regularization_L1
            loss += model.regularization_L1 * sum(abs,w)
        end
        if model.regularization_L2 !== 0
            #@show model.regularization_L2,size(w)
            loss += model.regularization_L2 * sum(abs2,w)
        end
    end
    return loss
end

#=
"""
"""
=#





#=

imax,jmax = size(mask)

reduce = 2^length(enc_nfilter_internal)
# size after encoder part of convolutional network

sz_inner = (imax ?? reduce,
            jmax ?? reduce,
            enc_nfilter_internal[end])

ndensein = prod(sz_inner)

@show ndensein


inner = Chain((Dense(ndensein,ndensein ?? 5,dropout_rate_train),
               Dense(ndensein ?? 5,ndensein,dropout_rate_train),
               x -> reshape(x,(sz_inner[1],sz_inner[2],sz_inner[3],:)),
               ))
=#

# mode=0: 0 for max, 1 for average including padded values, 2 for average excluding padded values.
#const pool_mode = 0; # max pooling
const pool_mode = 1; # average pooling

const mypool(x) = pool(x; mode = pool_mode)

function showsize(x)
    @show size(x)
    return x
end

# model = Model(Chain((
#     CatSkip(Chain((
#         Conv(3,3,enc_nfilter[1],enc_nfilter[2]),
#         mypool,
#         CatSkip(Chain((
#             Conv(3,3,enc_nfilter[2],enc_nfilter[3]),
#             mypool,
#             CatSkip(Chain((
#                 Conv(3,3,enc_nfilter[3],enc_nfilter[4]),
#                 mypool,
#                 CatSkip(Chain((
#                     Conv(3,3,enc_nfilter[4],enc_nfilter[5]),
#                     mypool,
#                     #x -> pool(x, mode = 2, padding = (1,0)),
#                     inner,
#                     upsample,
#                     #x -> x[1:end-1,:,:,:],
#                 ))),
#                 Conv(3,3,enc_nfilter[5]+enc_nfilter[4],enc_nfilter[4]),
#                 upsample))),
#             Conv(3,3,enc_nfilter[4]+enc_nfilter[3],enc_nfilter[3]),
#             upsample))),
#         Conv(3,3,enc_nfilter[3]+enc_nfilter[2],enc_nfilter[2]),
#         upsample))),
#     Conv(3,3,enc_nfilter[2]+enc_nfilter[1],2,identity))))


function recmodel(sz,enc_nfilter,l=1)
    if l+1 == length(enc_nfilter)
        return CatSkip(Chain((
            Conv((3,3),enc_nfilter[l],enc_nfilter[l+1]),
                    mypool,
                    #x -> pool(x, mode = 2, padding = (1,0)),
                    inner,
                    upsample,
                    #x -> x[1:end-1,:,:,:],
                )))
    else
        return CatSkip(Chain((
            Conv((3,3),enc_nfilter[l],enc_nfilter[l+1]),
            mypool,
            recmodel(sz,enc_nfilter,l+1),
            Conv((3,3),enc_nfilter[l+2]+enc_nfilter[l+1],enc_nfilter[l+1]),
            upsample)))
    end
end



# remove padding from x
function croppadding(x,odd)
    r = ntuple(i -> 1:(size(x,i)-odd[i]), length(odd))
    return x[r...,:,:]
end

function croppadding2(x,odd)
    r = ntuple(i -> ((odd[i]==1) ? (1:size(x,i)-1) : (2:size(x,i)-1) ), length(odd))
    return x[r...,:,:]
end

function recmodel3(sz,enc_nfilter,l=1; method = :nearest)
    # for 2D
    # convkernel = (3,3)
    # upkernel = (2,2)

    convkernel = ntuple(i -> 3, length(sz))
    upkernel = ntuple(i -> 2, length(sz))

    # activation function
    f =
        if l == 1
            identity
        else
            relu
        end

    odd = map(x -> x % 2,sz)
    pool_mode = 1; # average pooling
    mypool(x) = pool(x; mode = pool_mode, padding = odd)

    # size after pooling
    sz_small = sz.??2 .+ odd

    if l == length(enc_nfilter)
        return identity
    else
        return SumSkip( Chain((Conv(convkernel,enc_nfilter[l],enc_nfilter[l+1]),
                               mypool,
                               recmodel3(sz_small,enc_nfilter,l+1, method = method),
                               Upsample(sz_small, enc_nfilter[l+1], method = method),
                               x -> croppadding(x,odd),
                               Conv(convkernel,enc_nfilter[l+1],enc_nfilter[l],f))))
       #return Conv(convkernel,enc_nfilter[l],enc_nfilter[l+1])
    end
end

function recmodel4(sz,enc_nfilter,skipconnections,l=1; method = :nearest)
    # for 2D
    # convkernel = (3,3)
    # upkernel = (2,2)

    convkernel = ntuple(i -> 3, length(sz))
    upkernel = ntuple(i -> 2, length(sz))

    # activation function
    f =
        if l == 1
            identity
        else
            relu
        end

    odd = map(x -> x % 2,sz)
    pool_mode = 1; # average pooling
    mypool(x) = pool(x; mode = pool_mode, padding = odd)

    # size after pooling
    sz_small = sz.??2 .+ odd

    if l == length(enc_nfilter)
        return identity
    else
        inner = Chain((Conv(convkernel,enc_nfilter[l],enc_nfilter[l+1]),
                       mypool,
                       recmodel4(sz_small,enc_nfilter,skipconnections,l+1, method = method),
                       Upsample(sz_small, enc_nfilter[l+1], method = method),
                       x -> croppadding(x,odd),
                       Conv(convkernel,enc_nfilter[l+1],enc_nfilter[l],f)))

        if l in skipconnections
            println("skip connections at level $l")
            return SumSkip(inner)
        else
            return inner
        end
    end
end



function recmodel_bn(sz,enc_nfilter,l=1; method = :nearest)
    # for 2D
    # convkernel = (3,3)
    # upkernel = (2,2)

    convkernel = ntuple(i -> 3, length(sz))
    upkernel = ntuple(i -> 2, length(sz))

    # activation function
    f =
        if l == 1
            identity
        else
            relu
        end

    odd = map(x -> x % 2,sz)
    pool_mode = 1; # average pooling
    mypool(x) = pool(x; mode = pool_mode, padding = odd)

    # size after pooling
    sz_small = sz.??2 .+ odd

    if l == length(enc_nfilter)
        return identity
    else
        return SumSkip( Chain((ConvBN(convkernel,enc_nfilter[l],enc_nfilter[l+1]),
                               mypool,
                               recmodel_bn(sz_small,enc_nfilter,l+1, method = method),
                               Upsample(sz_small, enc_nfilter[l+1], method = method),
                               x -> croppadding(x,odd),
                               ConvBN(convkernel,enc_nfilter[l+1],enc_nfilter[l],f))))
       #return Conv(convkernel,enc_nfilter[l],enc_nfilter[l+1])
    end
end


function recmodel_noskip(sz,enc_nfilter,l=1; method = :nearest)
    # for 2D
    # convkernel = (3,3)
    # upkernel = (2,2)

    convkernel = ntuple(i -> 3, length(sz))
    upkernel = ntuple(i -> 2, length(sz))

    # activation function
    f =
        if l == 1
            identity
        else
            relu
        end

    odd = map(x -> x % 2,sz)
    pool_mode = 1; # average pooling
    mypool(x) = pool(x; mode = pool_mode, padding = odd)

    # size after pooling
    sz_small = sz.??2 .+ odd

    if l == length(enc_nfilter)
        return identity
    else
        return Chain((Conv(convkernel,enc_nfilter[l],enc_nfilter[l+1]),
                      mypool,
                      recmodel_noskip(sz_small,enc_nfilter,l+1; method = method),
                      Upsample(sz_small, enc_nfilter[l+1], method = method),
                      x -> croppadding(x,odd),
                      Conv(convkernel,enc_nfilter[l+1],enc_nfilter[l],f)))
    end
end

"""
    reconstruct(Atype,data_all,fnames_rec;...)

Train a neural network to reconstruct missing data using the training data set
and periodically run the neural network on the test dataset. The data is assumed to be
avaialable on a regular longitude/latitude grid (which is the case of L3
satellite data).

## Mandatory parameters

* `Atype`: array type to use
* `data_all`: list of named tuples. Every tuple should have `filename`, and `varname`.
`data_all[1]` will be used for training (and perturbed to prevent overfitting).
All others entries `data_all[2:end]` will be reconstructed using the training network
at the epochs defined by `save_epochs`.
* `fnames_rec`: vector of filenames corresponding to the entries `data_all[2:end]`


## Optional parameters:

 * `epochs`: the number of epochs (default `1000`)
 * `batch_size`: the size of a mini-batch (default `50`)
 * `enc_nfilter_internal`: number of filter of the internal encoding layers (default `[16,24,36,54]`)
 * `skipconnections`: list of layers with skip connections (default `2:(length(enc_nfilter_internal)+1)`)
 * `clip_grad`: maximum allowed gradient. Elements of the gradients larger than this values will be clipped (default `5.0`).
 * `regularization_L2_beta`: Parameter for L2 reguliziation (default `0`, i.e. no regularization)
 * `save_epochs`: list of epochs where the results should be saved (default `200:10:epochs`)
 * `is3D`: Switch to apply 2D (`is3D == false`) or 3D (`is3D == true`) convolutions (default `false`)
 * `upsampling_method`: interpolation method during upsampling which can be either `:nearest` or `:bilinear` (default `:nearest`)
 * `ntime_win`: number of time instance within the time window. This number should be odd. (default `3`)
 * `learning_rate`: intial learning rate of the ADAM optimizater (default `0.001`)
 * `learning_rate_decay_epoch`: The exponential recay rate of the leaning rate. After `learning_rate_decay_epoch` the learning rate is halved. The learning rate is compute as  `learning_rate * 0.5^(epoch / learning_rate_decay_epoch)`. `learning_rate_decay_epoch` can be `Inf` for a constant learning rate (default)
 * `min_std_err`: minimum error standard deviation preving a division close to zero (default `exp(-5) = 0.006737946999085467`)
 * `loss_weights_refine`: The weigh of the individual refinement layers using in the cost function. 
If `loss_weights_refine` has a single element, then there is no refinement.  (default `(1.,)`)


!!! note
    Note that also the optional parameters should be to tuned for a particular
    application.
"""
function reconstruct(Atype,data_all,fnames_rec;
                     epochs = 1000,
                     batch_size = 50,
                     #dropout_rate_train = 0.3,
                     truth_uncertain = false,
                     enc_nfilter_internal = [16,24,36,54],
                     skipconnections = 2:(length(enc_nfilter_internal)+1),
                     clip_grad = 5.0,
                     regularization_L2_beta = 0,
                     save_epochs = min(epochs,200):10:epochs,
                     is3D = false,
                     upsampling_method = :nearest,
                     ntime_win = 3,
                     learning_rate = 0.001,
                     learning_rate_decay_epoch = Inf,
                     min_std_err = 0.006737946999085467,
                     loss_weights_refine = (1.,),
)
    DB(Atype,d,batch_size) = (Atype.(tmp) for tmp in DataLoader(d,batch_size))

    if isempty(save_epochs) || epochs < minimum(save_epochs)
        error("No output will be saved. Consider to adjust save_epochs (currently $save_epochs) or epochs (currently $epochs).")
    end

    varname = data_all[1][1].varname

    if !is3D
        nvar = 4 + 2*ntime_win*length(data_all[1])
    else
        nvar = 4 + 2*length(data_all[1])
    end

    enc_nfilter = vcat([nvar],enc_nfilter_internal)

    @info "Number of threads: $(Threads.nthreads())"

    # first element in data_all is for training
    data_sources = [DINCAE.NCData(
        d,train = i == 1,
        ntime_win = ntime_win,
        is3D = is3D,
    ) for (i,d) in enumerate(data_all)]

    # use common mean
    for i = 2:length(data_all)
        data_sources[i].meandata .= data_sources[1].meandata
    end

    #data_iter = [PrefetchDataIter(DINCAE.DataBatches(Atype,ds,batch_size)) for ds in data_sources]
    data_iter = [DINCAE.DataBatches(Atype,ds,batch_size) for ds in data_sources]
    #data_iter = [DB(Atype,ds,batch_size) for ds in data_sources]

    train = data_iter[1]
    train_data = data_sources[1]

    all_varnames = map(v -> v.varname,data_all[1])
    output_varnames = all_varnames[train_data.isoutput]

    @info "Output variables:  $output_varnames"

    # number of output variables
    noutput = sum(train_data.isoutput)

    @info "Number of filters: $enc_nfilter"
    inputs_,xtrue = first(train)
    sz = size(inputs_)

    @info "Input size:        $(format_size(sz))"
    @info "Input sum:         $(sum(inputs_))"

    gamma = log(min_std_err^(-2))
    @info "Gamma:             $gamma"

    @info "Number of filters: $enc_nfilter"
    if loss_weights_refine == (1.,)
        model = Model(DINCAE.recmodel3(
            sz[1:end-2],
            enc_nfilter,method = upsampling_method),truth_uncertain,gamma)
    else
        println("Step model")

        enc_nfilter2 = copy(enc_nfilter)
        enc_nfilter2[1] += 2*noutput
        @info "Number of filters (refinement): $enc_nfilter2"

        steps = (DINCAE.recmodel4(sz[1:2],enc_nfilter,skipconnections; method = upsampling_method),
                 DINCAE.recmodel4(sz[1:2],enc_nfilter2,skipconnections; method = upsampling_method))

        model = StepModel(steps,noutput,loss_weights_refine,truth_uncertain,gamma)
    end

    # TODO reduce output size to 2*noutput

    xrec = model(Atype(inputs_))
    @info "Output size:       $(format_size(size(xrec)))"
    @info "Output range:      $(extrema(Array(xrec)))"
    @info "Output sum:        $(sum(xrec))"

    loss = model(Atype(inputs_), Atype(xtrue))
    @info "Initial loss:      $loss"

    losses = typeof(loss)[]

    for fname_rec in fnames_rec
        if isfile(fname_rec)
            rm(fname_rec)
        end
    end


    # loop over epochs
    @time for e = 1:epochs
    #Juno.@profile @time  for e = 1:epochs

        lr = learning_rate * 0.5^(e / learning_rate_decay_epoch)

        N = 0
        loss_sum = 0
        # loop over training datasets
        for (ii,loss) in enumerate(adam(model, DINCAE.PrefetchDataIter(train); gclip = clip_grad, lr = lr))
            #for (ii,loss) in enumerate(adam(model, train; gclip = clip_grad, lr = lr))
            loss_sum += loss
            N += 1
        end
        push!(losses,loss_sum/N)
        println("epoch: $(@sprintf("%5d",e )) loss $(@sprintf("%5.4f",losses[end]))")
        flush(stdout)

        if e ??? save_epochs
            println("Save output $e")

            for (d_iter,fname_rec) in zip(data_iter[2:end],fnames_rec)
                @time for (ii,(inputs_,xtrue)) in enumerate(d_iter)
                    xrec = Array(model(inputs_))

                    if is3D
                        # take middle frame
                        xrec = xrec[:,:,(end+1)??2,:,:]
                    end

                    offset = (ii-1)*batch_size

                    DINCAE.savesample(
                        fname_rec,
                        output_varnames,xrec,
                        train_data.meandata[:,:,findall(train_data.isoutput)],
                        train_data.lon,
                        train_data.lat,
                        ii-1,offset)
                end
            end
        end

        shuffle!(train)
    end

    for fname_rec in fnames_rec
        mode = (isfile(fname_rec) ? "a" : "c")
        NCDataset(fname_rec,mode) do ds
            defVar(ds,"losses",losses,("epochs",))
        end
    end

    return losses
end
