# Utilities for creating and modifying vector spaces and TensorMaps.
# To be `included` in MERA.jl.

"""
A TensorMap from N indices to N indices.
"""
SquareTensorMap{N} = TensorMap{S1, N, N} where {S1}

"""
Given two vector spaces, create an isometric/unitary TensorMap from one to the other. This
is done by creating a random Gaussian tensor and SVDing it.
"""
function randomisometry(Vout, Vin, T=ComplexF64)
    temp = TensorMap(randn, T, Vout ← Vin)
    U, S, Vt = tsvd(temp)
    u = U * Vt
    return u
end

"""
Return the number of sites/indices `m` that an operator is supported on, assuming it is an
operator from `m` sites to `m` sites.
"""
support(op::SquareTensorMap{N}) where {N} = N

"""
Given a TensorMap from a number of indices to the same number of indices, expand its support
to a larger number of indices `n` by tensoring with the identity. The different ways of
doing the expansion, e.g. I ⊗ op and op ⊗ I, are averaged over.
"""
function expand_support(op::SquareTensorMap{N}, n::Integer) where {N}
    V = space(op, 1)
    eye = id(V)
    op_support = N
    while op_support < n
        opeye = op ⊗ eye
        eyeop = eye ⊗ op
        op = (opeye + eyeop)/2
        op_support += 1
    end
    return op
end

"""Strip a real ElementarySpace of its symmetry structure."""
remove_symmetry(V::ElementarySpace{ℝ}) = CartesianSpace(dim(V))
"""Strip a complex ElementarySpace of its symmetry structure."""
remove_symmetry(V::ElementarySpace{ℂ}) = ComplexSpace(dim(V), isdual(V))

""" Strip a TensorMap of its internal symmetries."""
function remove_symmetry(t::TensorMap)
    domain_nosym = reduce(⊗, map(remove_symmetry, domain(t)))
    codomain_nosym = reduce(⊗, map(remove_symmetry, codomain(t)))
    t_nosym = TensorMap(zeros, eltype(t), codomain_nosym ← domain_nosym)
    t_nosym.data[:] = convert(Array, t)
    return t_nosym
end

"""
Given a vector space and a dictionary of dimensions for the various irrep sectors, return
another vector space of the same kind but with these new dimension. If some irrep sectors
are not in the dictionary, the dimensions of the original space are used.
"""
function expand_vectorspace(V::CartesianSpace, newdim)
    d = length(newdim) > 0 ? first(values(newdim)) : dim(V)
    return typeof(V)(d)
end

function expand_vectorspace(V::ComplexSpace, newdim)
    d = length(newdim) > 0 ? first(values(newdim)) : dim(V)
    return typeof(V)(d, V.dual)
end

function expand_vectorspace(V::GeneralSpace, newdim)
    d = length(newdim) > 0 ? first(values(newdim)) : dim(V)
    return typeof(V)(d, V.dual, V.conj)
end

function expand_vectorspace(V::RepresentationSpace, newdims)
    olddims = Dict(s => dim(V, s) for s in sectors(V))
    sectordict = merge(olddims, newdims)
    return typeof(V)(sectordict; dual=V.dual)
end

"""
If the first argument given to depseudoserialize is a String, we assume its a representation
of a an object that can `eval`uated. So we evaluate it and call depseudoserialize again.
"""
depseudoserialize(str::String, args...) = depseudoserialize(eval(Meta.parse(str)), args...)

"""
Return a tuple of objects that can be used to reconstruct a given TensorMap, and that are
all of Julia base types.
"""
function pseudoserialize(t::T) where T <: TensorMap
    # We make use of the nice fact that many TensorKit objects return on repr
    # strings that are valid syntax to reconstruct these objects.
    domstr = repr(t.dom)
    codomstr = repr(t.codom)
    eltyp = eltype(t)
    if isa(t.data, AbstractArray)
        data = deepcopy(t.data)
    else
        data = Dict(repr(s) => deepcopy(d) for (s, d) in t.data)
    end
    return repr(T), domstr, codomstr, eltyp, data
end

"""
Reconstruct a TensorMap given the output of `pseudoserialize`.
"""
function depseudoserialize(::Type{T}, domstr, codomstr, eltyp, data) where T <: TensorMap
    # We make use of the nice fact that many TensorKit objects return on repr
    # strings that are valid syntax to reconstruct these objects.
    dom = eval(Meta.parse(domstr))
    codom = eval(Meta.parse(codomstr))
    t = TensorMap(zeros, eltyp, codom ← dom)
    if isa(t.data, AbstractArray)
        t.data[:] = data
    else
        for (irrepstr, irrepdata) in data
            irrep = eval(Meta.parse(irrepstr))
            t.data[irrep][:] = irrepdata
        end
    end
    return t
end

"""
Transform a TensorMap `t` to change the vector spaces of its indices. `spacedict` should be
a dictionary of index labels to VectorSpaces, that tells which indices should have their
space changed. Instead of a dictionary, a varargs of Pairs `index => vectorspace` also
works.

For each index `i`, its current space `Vorig = space(t, i)` and new space `Vnew =
spacedict[i]` should be of the same type. If `Vnew` is strictly larger than `Vold` then `t`
is padded with zeros to fill in the new elements. Otherwise some elements of `t` will be
truncated away.
"""
function pad_with_zeros_to(t::TensorMap, spacedict::Dict)
    # Expanders are the matrices by which each index will be multiplied to change the space.
    idmat(T, shp) = Array{T}(I, shp)
    expanders = [TensorMap(idmat, eltype(t), V ← space(t, ind)) for (ind, V) in spacedict]
    sizedomain = length(domain(t))
    sizecodomain = length(codomain(t))
    # Prepare the @ncon call that contracts each index of `t` with the corresponding
    # expander, if one exists.
    numinds = sizedomain + sizecodomain
    inds_t = [ind in keys(spacedict) ? ind : -ind for ind in 1:numinds]
    inds_expanders = [[-ind, ind] for ind in keys(spacedict)]
    tensors = [t, expanders...]
    inds = [inds_t, inds_expanders...]
    t_new_tensor = @ncon(tensors, inds)
    # Permute inds to have the codomain and domain match with those of the input.
    t_new = permute(t_new_tensor, tuple(1:sizecodomain...),
                    tuple(sizecodomain+1:numinds...))
    return t_new
end

pad_with_zeros_to(t::TensorMap, spaces...) = pad_with_zeros_to(t, Dict(spaces))

"""
Inner product of two tensors as tangents on a Stiefel manifold. The first argument is the
point on the manifold that we are at, the next two are the tangent vectors. A Stiefel
manifold is the manifold of isometric tensors, i.e. tensors that fulfill t't == I.
"""
function stiefel_inner(t::TensorMap, t1::TensorMap, t2::TensorMap)
    # TODO Could write a faster version for unitaries, where the two terms are the same.
    # TODO a1 and a2 are supposed to be skew-symmetric. Should we enforce or assume that?
    a1 = t'*t1
    a2 = t'*t2
    inner = tr(t1'*t2) - 0.5*tr(a1'*a2)
    return inner
end

function stiefel_geodesic_unitary(u::TensorMap, utan::TensorMap, alpha::Number)
    a = u' * utan
    # In a perfect world, a is already skew-symmetric, but for numerical errors we enforce
    # that.
    # TODO Should we instead raise a warning if this does not already hold?
    a = (a - a')/2
    m = exp(alpha * a)
    u_end = u * m
    utan_end = utan * m
    # Creeping numerical errors may cause loss of isometricity, so explicitly isometrize.
    # TODO Maybe check that S is almost all ones, alert the user if it's not.
    U, S, Vt = tsvd(u_end)
    u_end = U*Vt
    return u_end, utan_end
end

function stiefel_geodesic_isometry(w::TensorMap, wtan::TensorMap, alpha::Number)
    a = w' * wtan
    # In a perfect world, a is already skew-symmetric, but for numerical errors we enforce
    # that.
    # TODO Should we instead raise a warning if this does not already hold?
    a = (a - a')/2
    k = wtan - w * a
    q, r = leftorth(k)
    # TODO Remove the TensorKit. part once cats are exported.
    b = TensorKit.catcodomain(TensorKit.catdomain(a, -r'), TensorKit.catdomain(r, zero(a)))
    expb = exp(alpha * b)
    eye = id(domain(a))
    uppertrunc = TensorKit.catcodomain(eye, zero(eye))
    lowertrunc = TensorKit.catcodomain(zero(eye), eye)
    m = uppertrunc' * expb * uppertrunc
    n = lowertrunc' * expb * uppertrunc
    w_end = w*m + q*n
    wtan_end = wtan*m - w*r'*n
    # Creeping numerical errors may cause loss of isometricity, so explicitly isometrize.
    # TODO Maybe check that S is almost all ones, alert the user if it's not.
    U, S, Vt = tsvd(w_end)
    w_end = U*Vt
    return w_end, wtan_end
end

# TODO These can be optimized.

function cayley_retract(x::TensorMap, tan::TensorMap, alpha::Number)
    dom = domain(x)
    codom = codomain(x)
    domfuser = isomorphism(fuse(dom), dom)
    codomfuser = isomorphism(fuse(codom), codom)
    x = codomfuser * x * domfuser'
    tan = codomfuser * tan * domfuser'
    xtan = x' * tan
    Ptan = tan - 0.5*(x * xtan)
    u = TensorKit.catdomain(Ptan, x)
    v = TensorKit.catdomain(x, -Ptan)
    eye = id(domain(u))
    m1 = v' * x
    m2 = v' * u
    m3 = inv(eye - (alpha/2) * m2) * m1
    x_end = x + alpha * u * m3
    m23 = m2 * m3
    tan_end = u * (m1 + (alpha/2) * m23 + (alpha/2) * inv(eye - (alpha/2) * m2) * m23)
    x_end = codomfuser' * x_end * domfuser
    tan_end = codomfuser' * tan_end * domfuser
    return x_end, tan_end
end

function cayley_transport(x::TensorMap, tan::TensorMap, vec::TensorMap, alpha::Number)
    xtan = x' * tan
    Ptan = tan - 0.5*(x * xtan)
    u = TensorKit.catdomain(Ptan, x)
    v = TensorKit.catdomain(x, -Ptan)
    M = id(domain(u)) - (alpha/2) * v' * u
    Minv = inv(M)
    vec_end = vec + alpha * (u * (Minv * (v' * vec)))
    return uvec_end
end

function istangent_isometry(u, utan)
    a = u' * utan
    return all(a ≈ -a')
end
