# This supports nonbroadcasting math on NamedDimArrays

# Matrix product
valid_matmul_dims(a::Tuple{Symbol}, b::Tuple{Vararg{Symbol}}) = true
function valid_matmul_dims(a::Tuple{Symbol,Symbol}, b::Tuple{Vararg{Symbol}})
    a_dim = a[end]
    b_dim = b[1]

    return a_dim === b_dim || a_dim === :_ || b_dim === :_
end

matmul_names((a1, a2)::Tuple{Symbol,Symbol}, (b,)::Tuple{Symbol}) = (a1,)
matmul_names((a1, a2)::Tuple{Symbol,Symbol}, (b1, b2)::Tuple{Symbol,Symbol}) = (a1, b2)
matmul_names((a1,)::Tuple{Symbol}, (b1, b2)::Tuple{Symbol,Symbol}) = (a1, b2)

function throw_matrix_dim_error(a, b)
    msg = "Cannot take matrix product of arrays with different inner dimension names. $a vs $b"
    return throw(DimensionMismatch(msg))
end

function matrix_prod_names(a, b)
    # 0 Allocations. See `@btime (()-> matrix_prod_names((:foo, :bar),(:bar,)))()`
    valid_matmul_dims(a, b) || throw_matrix_dim_error(a, b)
    res = matmul_names(a, b)
    return compile_time_return_hack(res)
end

for (NA, NB) in ((1, 2), (2, 1), (2, 2))  #Vector * Vector, is not allowed
    @eval function Base.:*(
        a::NamedDimsArray{A,T,$NA}, b::NamedDimsArray{B,S,$NB},
    ) where {A,B,T,S}
        L = matrix_prod_names(A, B)
        data = *(parent(a), parent(b))
        return NamedDimsArray{L}(data)
    end
end

# vector^T * vector
function Base.:*(
    a::NamedDimsArray{A,T,2,<:CoVector}, b::NamedDimsArray{B,S,1},
) where {A,B,T,S}
    valid_matmul_dims(A, B) || throw_matrix_dim_error(last(A), first(B))
    return *(parent(a), parent(b))
end

function Base.:*(a::NamedDimsArray{L,T,2,<:CoVector}, b::AbstractVector) where {L,T}
    return *(parent(a), b)
end

# Using `CoVector` results in Method ambiguities; have to define more specific methods.
for A in (Adjoint{<:Number,<:AbstractVector}, Transpose{<:Real,<:AbstractVector{<:Real}})
    @eval function Base.:*(a::$A, b::NamedDimsArray{L,T,1,<:AbstractVector{T}}) where {L,T}
        return *(a, parent(b))
    end
end

"""
    @declare_matmul(MatrixT, VectorT=nothing)

This macro helps define matrix multiplication for the types
with 2D type parameterization `MatrixT` and 1D `VectorT`.
It defines the various overloads for `Base.:*` that are required.
It should be used at the top level of a module.
"""
macro declare_matmul(MatrixT, VectorT=nothing)
    dim_combos = VectorT === nothing ? ((2, 2),) : ((1, 2), (2, 1), (2, 2))
    codes = map(dim_combos) do (NA, NB)
        TA_named = :(NamedDims.NamedDimsArray{<:Any,<:Any,$NA})
        TB_named = :(NamedDims.NamedDimsArray{<:Any,<:Any,$NB})
        TA_other = (VectorT, MatrixT)[NA]
        TB_other = (VectorT, MatrixT)[NB]

        quote
            function Base.:*(a::$TA_named, b::$TB_other)
                return *(a, NamedDims.NamedDimsArray{dimnames(b)}(b))
            end
            function Base.:*(a::$TA_other, b::$TB_named)
                return *(NamedDims.NamedDimsArray{dimnames(a)}(a), b)
            end
        end
    end
    return esc(Expr(:block, codes...))
end

# The following two methods can be defined by using
# @declare_matmul(Diagonal, AbstractVector)
# but that overwrites existing *(1D NDA, Vector) methods
# should improve the macro above to deal with this case
function Base.:*(a::Diagonal, b::NamedDimsArray{<:Any,<:Any,1})
    return *(NamedDimsArray{dimnames(a)}(a), b)
end

function Base.:*(a::NamedDimsArray{<:Any,<:Any,1}, b::Diagonal)
    return *(a, NamedDimsArray{dimnames(b)}(b))
end

@declare_matmul(AbstractMatrix, AbstractVector)
@declare_matmul(
    Adjoint{<:Any,<:AbstractMatrix{T1}} where {T1}, Adjoint{<:Any,<:AbstractVector}
)
@declare_matmul(Diagonal,)

function Base.inv(nda::NamedDimsArray{L,T,2}) where {L,T}
    data = inv(parent(nda))
    names = reverse(L)
    return NamedDimsArray{names}(data)
end

# Statistics
for fun in (:cor, :cov)
    @eval function Statistics.$fun(a::NamedDimsArray{L,T,2}; dims=1, kwargs...) where {L,T}
        numerical_dims = dim(a, dims)
        data = Statistics.$fun(parent(a); dims=numerical_dims, kwargs...)
        names = symmetric_names(L, numerical_dims)
        return NamedDimsArray{names}(data)
    end
end

function symmetric_names(L::Tuple{Symbol,Symbol}, dims::Integer)
    # 0 Allocations. See `@btime (()-> symmetric_names((:foo, :bar), 1))()`
    names = if dims == 1
        (L[2], L[2])
    elseif dims == 2
        (L[1], L[1])
    else
        (:_, :_)
    end
    return compile_time_return_hack(names)
end

# LinearAlgebra
#==
    Note on implementation of factorisition types:
    The general strategy is to make one of the fields of the factorization types
    into a NamedDimsArray.
    We can then dispatch on this as required, and strip it out with `parent` for accessing operations.
    However, the type of the field does not actually always match to what it should be
    from a mathematical perspective.
    Which is corrected in `Base.getproperty`, as required
==#

## lu

function LinearAlgebra.lu!(nda::NamedDimsArray{L}, args...; kwargs...) where L
    inner_lu = lu!(parent(nda), args...; kwargs...)
    factors = NamedDimsArray{L}(getfield(inner_lu, :factors))
    ipiv = getfield(inner_lu, :ipiv)
    info = getfield(inner_lu, :info)
    return LU(factors, ipiv, info)
end

function Base.parent(fact::LU{T,<:NamedDimsArray{L}}) where {T, L}
    factors = parent(getfield(fact, :factors))
    ipiv = getfield(fact, :ipiv)
    info = getfield(fact, :info)
    return LU(factors, ipiv, info)
end

function Base.getproperty(fact::LU{T,<:NamedDimsArray{L}}, d::Symbol) where {T, L}
    inner = getproperty(parent(fact), d)
    n1, n2 = L
    if d == :L
        return NamedDimsArray{(n1, :_)}(inner)
    elseif d == :U
        return NamedDimsArray{(:_, n2)}(inner)
    elseif d == :P
        perm_matrix_labels = (first(L), first(L))
        return NamedDimsArray{perm_matrix_labels}(inner)
    elseif d == :p
        perm_vector_labels = (first(L),)
        return NamedDimsArray{perm_vector_labels}(inner)
    else
        return inner
    end
end

## lq

LinearAlgebra.lq(nda::NamedDimsArray, args...; kws...) = lq!(copy(nda), args...; kws...)
function LinearAlgebra.lq!(nda::NamedDimsArray{L}, args...; kwargs...) where L
    inner = lq!(parent(nda), args...; kwargs...)
    factors = NamedDimsArray{L}(getfield(inner, :factors))
    τ = getfield(inner, :τ)
    return LQ(factors, τ)
end

function Base.parent(fact::LQ{T,<:NamedDimsArray{L}}) where {T, L}
    factors = parent(getfield(fact, :factors))
    τ = getfield(fact, :τ)
    return LQ(factors, τ)
end

function Base.getproperty(fact::LQ{T,<:NamedDimsArray{L}}, d::Symbol) where {T, L}
    inner = getproperty(parent(fact), d)
    n1, n2 = L
    if d == :L
        return NamedDimsArray{(n1, :_)}(inner)
    elseif d == :Q
        return NamedDimsArray{(:_, n2)}(inner)
    else
        return inner
    end
end

## svd

function LinearAlgebra.svd(nda::NamedDimsArray{L, T}, args...; kwargs...) where {L, T}
    return svd!(
        LinearAlgebra.copy_oftype(nda, LinearAlgebra.eigtype(T)),
        args...;
        kwargs...
    )
end

function LinearAlgebra.svd!(nda::NamedDimsArray{L}, args...; kwargs...) where L
    inner = svd!(parent(nda), args...; kwargs...)
    u = NamedDimsArray{L}(getfield(inner, :U))
    s = getfield(inner, :S)
    vt = NamedDimsArray{L}(getfield(inner, :Vt))
    return SVD(u, s, vt)
end

function Base.parent(fact::SVD{T, Tr, <:NamedDimsArray{L}}) where {T, Tr, L}
    u = parent(getfield(fact, :U))
    s = getfield(fact, :S)
    vt = parent(getfield(fact, :Vt))
    return SVD(u, s, vt)
end

function Base.getproperty(fact::SVD{T, Tr, <:NamedDimsArray{L}}, d::Symbol) where {T, Tr, L}
    inner = getproperty(parent(fact), d)
    n1, n2 = L
    if d == :U
        return NamedDimsArray{(n1,:_)}(inner)
    elseif d == :V
        return NamedDimsArray{(:_, n2)}(inner)
    elseif d == :Vt
        return NamedDimsArray{(n2,:_)}(inner)
    else # :S
        return inner
    end
end
