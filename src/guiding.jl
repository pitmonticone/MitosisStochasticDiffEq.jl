function range2ind(ts::AbstractRange, t)
  indx = round(Int, (t-first(ts))/step(ts))
  indx += one(indx)
end

function range2ind(ts::AbstractVector, t)
  r = searchsorted(ts, t)
  r1 = minimum((first(r),length(ts)))
  r2 = maximum((last(r),one(last(r))))
  return abs(ts[r1] - t) < abs(ts[r2] - t) ? r1 : r2
end

unpackx(a) = @view a[1:end-1]
mypack(a::SArray,c::Number) = SArray([a; c])
mypack(a,c::Number) = [a; c]

# linear approximation
(a::AffineMap)(u,p,t) = a.B*u .+ a.β
(a::ConstantMap)(u,p,t) = a.x

# guided drift
function (G::GuidingDriftCache)(du,u,p,t)
  @unpack k, message = G
  @unpack f, g = k
  @unpack ktilde, ts, soldis, sol = message

  x = unpackx(u)
  dx = unpackx(du)
  d = length(x)

  # find cursor
  @inbounds cur_time = range2ind(ts, t)

  if isapprox(t, ts[cur_time]; atol = 1000eps(typeof(t)), rtol = 1000eps(t))
    # non-interpolating version
    # take care for multivariate case here if P isa Matrix, ν  isa Vector, c isa Scalar
    # ν, P, c
    ν = @view soldis[1:d,cur_time]
    P = reshape(@view(soldis[d+1:d+d*d,cur_time]), d, d)
  else
    ν = @view sol(t)[1:d]
    P = reshape(@view(sol(t)[d+1:d+d*d]), d, d)
  end

  r = P\(ν - x)

  du[end] = dot(f(x,p,t) - ktilde.f(x,ktilde.p,t), r) - 0.5*tr((outer_(g(x,p,t)) - outer_(ktilde.g(x,ktilde.p,t)))*(inv(P) - outer_(r)))
  dx[:] .= vec(f(x, p, t) + (outer_(g(x, p, t))*r)) # evolution guided by observations
  
  return nothing
end

function (G::GuidingDriftCache)(u,p,t)
  @unpack k, message = G
  @unpack f, g = k
  @unpack ktilde, ts, soldis, sol = message

  x = unpackx(u)
  d = length(x)

  # find cursor
  @inbounds cur_time = range2ind(ts, t)

  if isapprox(t, ts[cur_time]; atol = 1000eps(typeof(t)), rtol = 1000eps(t))
    # non-interpolating version
    # take care for multivariate case here if P isa Matrix, ν  isa Vector, c isa Scalar
    # ν, P, c
    ν = @view soldis[1:d,cur_time]
    P = reshape(@view(soldis[d+1:d+d*d,cur_time]), d, d)
  else
    ν = @view sol(t)[1:d]
    P = reshape(@view(sol(t)[d+1:d+d*d]), d, d)
  end

  r = P\(ν .- x)

  dl = dot(f(x,p,t) -  ktilde.f(x,ktilde.p,t), r) - 0.5*tr((outer_(g(x,p,t)) - outer_(ktilde.g(x,ktilde.p,t)))*(inv(P) - outer_(r)))
  dx = vec(f(x, p, t) + outer_(g(x, p, t))*r) # evolution guided by observations

  return mypack(dx, dl)
end

# guided diffusion
function (G::GuidingDiffusionCache)(du,u,p,t)
  @unpack g = G

  x = @view u[1:end-1]
  du[1:end-1] .= g(x,p,t)
  return nothing
end

function (G::GuidingDiffusionCache)(u,p,t)
  @unpack g = G

  x = @view u[1:end-1]
  dx = g(x,p,t)
  return [dx; zero(eltype(u))]
end


function forwardguiding(k::SDEKernel, message, (x0, ll0), Z=nothing; alg=EM(false),
    dt=get_dt(k.trange), isadaptive=StochasticDiffEq.isadaptive(alg),
    numtraj=nothing, ensemblealg=EnsembleThreads(), output_func=(sol,i) -> (sol,false),
    inplace=true, kwargs...)

  @unpack f, g, trange, p = k

  u0 = mypack(x0,ll0)

  guided_f = GuidingDriftCache(k,message)
  guided_g = GuidingDiffusionCache(g)

  if Z!==nothing
    prob = SDEProblem{inplace}(guided_f, guided_g, u0, get_tspan(trange), p, noise=Z)
  else
    prob = SDEProblem{inplace}(guided_f, guided_g, u0, get_tspan(trange), p)
  end

  if numtraj==nothing
    sol = solve(prob, alg, dt=dt, adaptive=isadaptive; kwargs...)
  else
    ensembleprob = EnsembleProblem(prob, output_func = output_func)
    sol = solve(ensembleprob, alg, ensemblealg=ensemblealg,
        dt=dt, adaptive=isadaptive, trajectories=numtraj; kwargs...)
  end

  return sol, sol[end][end]
end
