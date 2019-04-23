using NamedDims
using NamedDims: names
using Test

@testset "dropdims" begin
    nda = NamedDimsArray{(:a, :b, :c, :d)}(ones(10, 1, 1, 20))

    @test_throws ArgumentError dropdims(nda; dims=1)
    @test_throws ArgumentError dropdims(nda; dims=:a)

    @test dropdims(nda; dims=:b) == ones(10, 1, 20) == dropdims(nda; dims=2)
    @test names(dropdims(nda; dims=:b)) == (:a, :c, :d) == names(dropdims(nda; dims=2))

    @test dropdims(nda; dims=(:b,:c)) == ones(10, 20) == dropdims(nda; dims=(2, 3))
    @test names(dropdims(nda; dims=(:b, :c))) == (:a, :d) == names(dropdims(nda; dims=(2, 3)))
end

@testset "$f" for f in (adjoint, transpose, permutedims)
    @testset "Vector $f" begin
        ndv = NamedDimsArray{(:foo,)}([10,20,30])
        @test f(ndv) == [10 20 30]
        @test names(f(ndv)) == (:_, :foo)


        if f === permutedims
            # unlike adjoint and tranpose, permutedims should not be its own inverse
            # The new dimension should stick around
            @test f(f(ndv)) == reshape([10, 20, 30], Val(2))
            @test names(f(f(ndv))) == (:foo, :_)
        else
            # Make sure vector double adjoint gets you back to the start.
            @test f(f(ndv)) == [10, 20, 30]
            @test names(f(f(ndv))) == (:foo,)
        end
    end

    @testset "Matrix $f" begin
        ndm = NamedDimsArray{(:foo,:bar)}([10 20 30; 11 22 33])
        @test f(ndm) == [10 11; 20 22; 30 33]
        @test names(f(ndm)) == (:bar, :foo)

        # Make sure implementation of matrix double adjoint is correct
        # since it is easy for the implementation of vector double adjoint broke it
        @test f(f(ndm)) == [10 20 30; 11 22 33]
        @test names(f(f(ndm))) == (:foo, :bar)
    end
end

@testset "permutedims" begin
    nda = NamedDimsArray{(:w,:x,:y,:z)}(ones(10,20,30,40))
    @test names(permutedims(nda, (:w,:x,:y,:z))) == (:w,:x,:y,:z) == names(permutedims(nda, 1:4))
    @test size(permutedims(nda, (:w,:x,:y,:z))) == (10,20,30,40) == size(permutedims(nda, 1:4))

    @test names(permutedims(nda, (:w,:y,:x,:z))) == (:w,:y,:x,:z) == names(permutedims(nda, (1,3,2,4)))
    @test size(permutedims(nda, (:w,:y,:x,:z))) == (10,30,20,40) == size(permutedims(nda, (1,3,2,4)))


    @test_throws Exception permutedims(nda, (:foo,:x,:y,:z))
    @test_throws Exception permutedims(nda, (:x,:y,:z))
    @test_throws Exception permutedims(nda, (:x,:x,:y,:z))

    @test_throws Exception permutedims(nda, (0,1,2,3))
    @test_throws Exception permutedims(nda, (2,3,4))
    @test_throws Exception permutedims(nda, (2,2,3,4))
end
