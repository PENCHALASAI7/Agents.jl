export OpenStreetMapSpace, OSMSpace, OSM

"""
    OSM
Submodule for functionality related to `OpenStreetMapSpace`.
See the docstring of the space for more info.
"""
module OSM # OpenStreetMap
using Agents
using LightOSM
using Graphs
using Pkg.Artifacts
using LinearAlgebra: dot, norm
using DataStructures

export TEST_MAP,
    random_road_position,
    plan_route!,
    map_coordinates,
    road_length,
    random_route!,
    latlon,
    intersection,
    road


# Stores information about an agent's path
struct OpenStreetMapPath
    route::Vector{Int}      # node IDs along path from `start` to `dest`
    start::Tuple{Int,Int,Float64} # Initial position of the agent
    dest::Tuple{Int,Int,Float64}    # Destination. `dest[1] == dest[2]` if this is an intersection
    return_route::Vector{Int}   # node IDs along path from `dest` to `start`
    has_to_return::Bool
end

# NOTE: All positions are indexed by vertex number and _not_ node id

"""
    OpenStreetMapSpace(path::AbstractString; kwargs...)
Create a space residing on the Open Street Map (OSM) file provided via `path`.
The functionality related to Open Street Map spaces is in the submodule `OSM`.

This space represents the underlying map as a *continuous* entity choosing accuracy over
performance by explicitly taking into account that every intersection is connected by
a road with a finite length in meters.
An example of its usage can be found in [Zombie Outbreak](@ref).
Nevertheless, all functions that target `DiscreteSpace`s apply here as well, e.g.
[`positions`](@ref). The discrete part are the underlying road intersections, that
are represented by a graph.

Much of the functionality of this space is provided by interfacing with
[OpenStreetMapX.jl](https://github.com/pszufe/OpenStreetMapX.jl), for example the two
keyword arguments `use_cache = false` and `trim_to_connected_graph = true` can be
passed into the `OpenStreetMapX.get_map_data` function.

For details on how to obtain an OSM file for your use case, consult the OpenStreetMapX.jl
README. We provide a variable `OSM.TEST_MAP` to use as a `path` for testing.

If your solution can tolerate routes to and from intersections only without caring for the
continuity of the roads in between, a faster implementation can be achieved by using the
[graph representation](https://pszufe.github.io/OpenStreetMapX.jl/stable/reference/#OpenStreetMapX.MapData)
of your map provided by OpenStreetMapX.jl. For tips on how to implement this, see our
integration example: [Social networks with Graphs.jl](@ref).

## The OSMAgent

The base properties for an agent residing on an `OSMSpace` are as follows:
```julia
mutable struct OSMAgent <: AbstractAgent
    id::Int
    pos::Tuple{Int,Int,Float64}
end
```

Current `pos`ition and `destination` tuples are represented as
`(start intersection index, finish intersection index, distance travelled in meters)`.
The `route` is an ordered list of intersections, providing a path to reach `destination`.

Further details can be found in [`OSMAgent`](@ref).

## Routing

There are two ways to generate a route, depending on the situation.
1. Assign the value of [`OSM.plan_route`](@ref) to the `.route` field of an Agent.
   This provides `:shortest` and `:fastest` paths (with the option of a `return_trip`)
   between intersections or positions.
2. [`OSM.random_route!`](@ref), choses a new `destination` an plans a new path to it;
   overriding the current route (if any).
"""
struct OpenStreetMapSpace <: Agents.DiscreteSpace # TODO: Why is this a discrete space?
    map::OSMGraph
    s::Vector{Vector{Int}}
    routes::Dict{Int,OpenStreetMapPath} # maps agent ID to corresponding path
end

function OpenStreetMapSpace(
    path::AbstractString;
)
    m = graph_from_file(path)
    agent_positions = [Int[] for _ in 1:Agents.nv(m.graph)]
    return OpenStreetMapSpace(m, agent_positions, Dict())
end

function Base.show(io::IO, s::OpenStreetMapSpace)
    print(
        io,
        "OpenStreetMapSpace with $(length(s.map.highways)) ways " *
        "and $(length(s.map.nodes)) nodes",
    )
end

function OSM_test_map()
    artifact_toml = joinpath(@__DIR__, "../../Artifacts.toml")
    map_hash = artifact_hash("osm_map_gottingen", artifact_toml)
    if isnothing(map_hash) || !artifact_exists(map_hash)
        map_hash = create_artifact() do artifact_dir
            download_osm_network(
                :place_name;
                save_to_file_location = joinpath(artifact_dir, "osm_map_gottingen.json"),
                place_name = "Gottingen"
            )
        end

        bind_artifact!(artifact_toml, "osm_map_gottingen", map_hash)
    end

    return joinpath(artifact_path(map_hash), "osm_map_gottingen.json")
end

#######################################################################################
# Custom functions for OSMSpace
#######################################################################################

# EXPORTED
"""
    OSM.random_road_position(model::ABM{<:OpenStreetMapSpace})

Similar to [`random_position`](@ref), but rather than providing only intersections, this method
returns a location somewhere on a road heading in a random direction.
"""
function random_road_position(model::ABM{<:OpenStreetMapSpace})
    # pick a random source and destination, and then a random distance on that edge
    s = Int(rand(model.rng, 1:Agents.nv(model)))
    d = Int(rand(model.rng, outneighbors(model.space.map.graph, s)))
    dist = rand(model.rng) * road_length(s, d, model)
    return (s, d, dist)
end

"""
    OSM.random_route!(agent, model::ABM{<:OpenStreetMapSpace})

Plan a new random route for the agent, by selecting a random destination and
planning a route from the agent's current position. Overwrite any current route.
"""
function random_route!(
    agent::A,
    model::ABM{<:OpenStreetMapSpace,A};
    return_trip = false,
    kwargs...
) where {A<:AbstractAgent}
    plan_route!(agent, random_road_position(model), model; return_trip, kwargs...)
end

"""
    OSM.plan_route!(agent, dest, model::ABM{<:OpenStreetMapSpace};
                   return_trip = false, kwargs...)

Plan a route from the current position of `agent` to the location specified in `dest`, which
can be an intersection or a point on a road.

If `return_trip = true`, a route will be planned from start -> finish -> start. All other
keywords are passed to [`LightOSM.shortest_path`](https://deloittedigitalapac.github.io/LightOSM.jl/docs/shortest_path/#LightOSM.shortest_path).

Returns `true` if a path to `dest` exists, and `false` if it doesn't. Specifying
`return_trip = true` also requires the existence of a return path for a route to be
planned.
"""
function plan_route!(
    agent::A,
    dest::Tuple{Int,Int,Float64},
    model::ABM{<:OpenStreetMapSpace,A};
    return_trip = false,
    kwargs...
) where {A<:AbstractAgent}
    if agent.pos[1] == agent.pos[2] == dest[1] == dest[2] ||    # identical start and end
        agent.pos == dest ||
        agent.pos == get_reverse_direction(dest, model)

        return true
    end

    if agent.pos[1:2] == dest[1:2] || agent.pos[1:2] == dest[2:-1:1]  # start and end on same road
        if agent.pos[1:2] == dest[2:-1:1]
            dest = get_reverse_direction(dest, model)
        end
        if agent.pos[3] < dest[3]   # same direction
            model.space.routes[agent.id] = OpenStreetMapPath(
                Int[],
                agent.pos,
                dest,
                Int[],
                return_trip
            )
        else    # opposite direction
            move_agent!(agent, get_reverse_direction(agent.pos, model), model)
            model.space.routes[agent.id] = OpenStreetMapPath(
                Int[],
                agent.pos,
                get_reverse_direction(dest, model),
                Int[],
                return_trip,
            )
        end
        return true
    end

    start_node = if agent.pos[1] == agent.pos[2] || 2.0 * agent.pos[3] < road_length(agent.pos, model)
        agent.pos[1]
    else
        agent.pos[2]
    end
    end_node = if dest[1] == dest[2] || 2.0 * dest[3] < road_length(dest, model)
        dest[1]
    else
        dest[2]
    end

    if start_node == end_node   # LightOSM.shortest_path fails in this case
        # either one of start or end is a node and the other an edge incident on it
        if agent.pos[1] == agent.pos[2]
            if dest[2] == agent.pos[1]
                dest = get_reverse_direction(dest, model)
            end
            move_agent!(agent, (dest[1], dest[2], 0.0), model)
            model.space.routes[agent.id] = OpenStreetMapPath(
                Int[],
                agent.pos,
                dest,
                return_trip ? Int[dest[1]] : Int[],
                return_trip,
            )
        elseif dest[1] == dest[2]
            if agent.pos[1] == dest[1]
                move_agent!(agent, get_reverse_direction(agent.pos, model), model)
            end
            model.space.routes[agent.id] = OpenStreetMapPath(
                Int[dest[1]],
                agent.pos,
                dest,
                Int[],
                return_trip,
            )
        # or both are edges incident on a common node
        else
            # swap around directions so that agent is moving toward common node
            # and destination is in the direction from common node to other node
            if agent.pos[1] == dest[2] || agent.pos[2] == dest[2]
                dest = get_reverse_direction(dest, model)
            end
            if agent.pos[1] == dest[1]
                move_agent!(agent, get_reverse_direction(agent.pos, model), model)
            end
            model.space.routes[agent.id] = OpenStreetMapPath(
                Int[dest[1]],
                agent.pos,
                dest,
                return_trip ? Int[dest[1]] : Int[],
                return_trip,
            )
        end
        return true
    end
    route = Int[]

    try
        route = shortest_path(
            model.space.map,
            model.space.map.index_to_node[start_node],
            model.space.map.index_to_node[end_node];
            kwargs...
        )
    catch
        return false
    end

    # convert back to graph indices
    for i in 1:length(route)
        route[i] = Int(model.space.map.node_to_index[route[i]])
    end

    # route won't be empty, those cases are already handled
    reverse!(route)

    # starting from this intersection, so remove it from route
    if agent.pos[1] == agent.pos[2]
        pop!(route)
    # move in reverse direction
    elseif length(route) > 1 && agent.pos[1] == route[end] && agent.pos[2] != route[end - 1]
        move_agent!(agent, get_reverse_direction(agent.pos, model), model)
    end

    return_route = Int[]
    if return_trip
        try
            return_route = 
                shortest_path(
                    model.space.map,
                    model.space.map.index_to_node[end_node],
                    model.space.map.index_to_node[start_node];
                    kwargs...
                )
        catch
            return false
        end
    end

    if return_trip
        # convert back to graph indices
        for i in 1:length(return_route)
            return_route[i] = Int(model.space.map.node_to_index[return_route[i]])
        end

        reverse!(return_route)
        # analogous case to forward route
        dest[1] == dest[2] && pop!(return_route)
        # will not check other case since dest shouldn't be flipped until
        # actually doing return trip
    end

    model.space.routes[agent.id] = OpenStreetMapPath(
        route,
        agent.pos,
        dest,
        return_route,
        return_trip,
    )
    return true
end

# Allows passing destination as an index
plan_route!(agent::A, dest::Int, model; kwargs...) where {A<:AbstractAgent} =
    plan_route!(agent, (dest, dest, 0.0), model; kwargs...)

"""
    OSM.latlon(pos, model)
    OSM.latlon(agent, model)

Return `(latitude, longitude)` of current road or intersection position.
"""
latlon(pos::Int, model::ABM{<:OpenStreetMapSpace}) =
    Tuple(model.space.map.node_coordinates[pos])

function latlon(pos::Tuple{Int,Int,Float64}, model::ABM{<:OpenStreetMapSpace})
    # extra checks to ensure consistency between both versions of `latlon`
    if pos[3] == 0.0 || pos[1] == pos[2]
        return latlon(pos[1], model)
    elseif pos[3] == road_length(pos, model)
        return latlon(pos[2], model)
    else
        gloc1 = get_geoloc(pos[1], model)
        gloc2 = get_geoloc(pos[2], model)
        dist = norm(LightOSM.to_cartesian(gloc1) .- LightOSM.to_cartesian(gloc2))
        dir = heading(gloc1, gloc2)
        geoloc = calculate_location(gloc1, dir, pos[3] / road_length(pos, model) * dist)
        return (geoloc.lat, geoloc.lon)
    end
end

latlon(agent::A, model::ABM{<:OpenStreetMapSpace,A}) where {A<:AbstractAgent} =
    latlon(agent.pos, model)

"""
    intersection(latlon::Tuple{Float64,Float64}, model::ABM{<:OpenStreetMapSpace})

Return the nearest intersection position to (latitude, longitude).
Quicker, but less precise than [`OSM.road`](@ref).
"""
function intersection(ll::Tuple{Float64,Float64}, model::ABM{<:OpenStreetMapSpace})
    vert = Int(model.space.map.node_to_index[nearest_node(model.space.map, [GeoLocation(ll..., 0.0)])[1][1][1]])
    return (vert, vert, 0.0)
end

"""
    OSM.road(latlon::Tuple{Float64,Float64}, model::ABM{<:OpenStreetMapSpace})

Return a location on a road nearest to (latitude, longitude).
Slower, but more precise than [`OSM.intersection`](@ref).
"""
function road(ll::Tuple{Float64,Float64}, model::ABM{<:OpenStreetMapSpace})
    best_sq_dist = Inf
    best = (-1, -1, -1.0)
    pt = LightOSM.to_cartesian(GeoLocation(ll..., 0.))
    for e in edges(model.space.map.graph)
        s = LightOSM.to_cartesian(GeoLocation(model.space.map.node_coordinates[src(e)]..., 0.))
        d = LightOSM.to_cartesian(GeoLocation(model.space.map.node_coordinates[dst(e)]..., 0.))
        road_vec = d .- s
        
        # closest point on line segment requires checking if perpendicular from point lies on line
        # segment. If not, use the closest end of the line segment
        if dot(pt .- s, road_vec) < 0.
            int_pt = s
        elseif dot(pt .- d, road_vec) > 0.
            int_pt = d
        else
            int_pt = s .+ (dot(pt .- s, road_vec) / dot(road_vec, road_vec)) .* road_vec
        end
        
        sq_dist = dot(int_pt .- pt, int_pt .- pt)
        
        if sq_dist < best_sq_dist
            best_sq_dist = sq_dist
            rd_dist = norm(int_pt .- s) / norm(road_vec) * road_length(Int(src(e)), Int(dst(e)), model)

            best = (
                Int(src(e)),
                Int(dst(e)),
                rd_dist,
            )
        end
    end

    return best
end

"""
    OSM.road_length(start::Int, finish::Int, model)
    OSM.road_length(pos::Tuple{Int,Int,Float64}, model)

Return the road length (in meters) between two intersections given by intersection ids.
"""
road_length(pos::Tuple{Int,Int,Float64}, model::ABM{<:OpenStreetMapSpace}) =
    road_length(pos[1], pos[2], model)
road_length(p1::Int, p2::Int, model::ABM{<:OpenStreetMapSpace}) =
    model.space.map.weights[p1, p2]

function Agents.is_stationary(agent, model::ABM{<:OpenStreetMapSpace})
    return !haskey(model.space.routes, agent.id)
end

"""
    get_geoloc(pos::Int, model::ABM{<:OpenStreetMapSpace})

Return `GeoLocation` corresponding to node `pos`
"""
get_geoloc(pos::Int, model::ABM{<:OpenStreetMapSpace}) = GeoLocation(model.space.map.node_coordinates[pos]..., 0.0)

"""
    get_reverse_direction(pos::Tuple{Int,Int,Float64}, model::ABM{<:OpenStreetMapSpace})

Returns the same position, but with `pos[1]` and `pos[2]` swapped and `pos[3]` updated accordingly
"""
get_reverse_direction(pos::Tuple{Int,Int,Float64}, model::ABM{<:OpenStreetMapSpace}) =
    (pos[2], pos[1], road_length(pos, model) - pos[3])

#######################################################################################
# Agents.jl space API
#######################################################################################

function Agents.random_position(model::ABM{<:OpenStreetMapSpace})
    vert = Int(rand(model.rng, 1:Agents.nv(model)))
    return (vert, vert, 0.0)
end

function Agents.add_agent_to_space!(
    agent::A,
    model::ABM{<:OpenStreetMapSpace,A},
) where {A<:AbstractAgent}
    push!(model.space.s[agent.pos[1]], agent.id)
    return agent
end

function Agents.remove_agent_from_space!(
    agent::A,
    model::ABM{<:OpenStreetMapSpace,A},
) where {A<:AbstractAgent}
    prev = model.space.s[agent.pos[1]]
    ai = findfirst(i -> i == agent.id, prev)
    deleteat!(prev, ai)
    return agent
end

function Agents.move_agent!(
    agent::A,
    pos::Tuple{Int,Int,Float64},
    model::ABM{<:OpenStreetMapSpace,A},
) where {A<:AbstractAgent}
    if pos[1] == agent.pos[1]
        agent.pos = pos
        return agent
    end
    Agents.remove_agent_from_space!(agent, model)
    agent.pos = pos
    Agents.add_agent_to_space!(agent, model)
end

"""
    move_along_route!(agent, model::ABM{<:OpenStreetMapSpace}, distance::Real)

Move an agent by `distance` in meters along its planned route.
"""
function Agents.move_along_route!(
    agent::A,
    model::ABM{<:OpenStreetMapSpace,A},
    distance::Real,
) where {A<:AbstractAgent}
    if is_stationary(agent, model)
        return nothing
    end

    # branching here corresponds to nesting of the following cases:
    # - Is the agent moving to the end of the road or somewhere in the middle (isempty(osmpath.route))
    # - Is `distance` more than the distance to the next waypoint / end of route (will it overshoot)?
    #   - Did we reach the end of the route? If so, does the agent need to return?
    #     - If the agent returns, what direction does it go in?
    #   - If we have another waypoint after this, move there
    # It might be easier to formulate this as a recursive structure, so recursive calls are annotated where necessary
    # instead of the loop this currently runs in. These annotations are marked with `##` just to make it clear.

    osmpath = model.space.routes[agent.id]
    while distance > 0
        if isempty(osmpath.route)   # last leg of route, to the middle of a road
            # distance left to reach dest
            dist_left = osmpath.dest[3] - agent.pos[3]
            if dist_left < distance # can overshoot destination
                distance -= dist_left
                move_agent!(agent, osmpath.dest, model) # reach destination
                if osmpath.has_to_return    # if we have to return
                    # empty return route implies we just have to go reverse on this edge
                    if isempty(osmpath.return_route)
                        osmpath = OpenStreetMapPath(
                            osmpath.return_route,
                            get_reverse_direction(osmpath.dest, model),
                            get_reverse_direction(osmpath.start, model),
                            Int[],
                            false,
                        )
                        move_agent!(agent, get_reverse_direction(agent.pos, model), model)
                        break
                        ## return
                    end

                    # non-empty return route
                    osmpath = OpenStreetMapPath(    # construct return path
                        osmpath.return_route,
                        osmpath.dest,
                        osmpath.start,
                        Int[],
                        false
                    )
                    # get next waypoint on return path
                    # this will either one of the endpoints of this road
                    next_wp = osmpath.route[end]
                    if next_wp == agent.pos[1]
                        # need to go back along same road, so reverse direction
                        move_agent!(agent, get_reverse_direction(agent.pos, model), model)
                    end
                    # move remaining distance along return path
                    continue
                    ## return Agents.move_along_route!(agent, model, distance)
                end
                # delete path data so this agent is recognized as stationary
                delete!(model.space.routes, agent.id)
                break
                ## return
            end
            # can't directly reach destination, so move distance along road
            # ensure we don't overshoot the destination
            result_pos = min(agent.pos[3] + distance, osmpath.dest[3])
            move_agent!(agent, (agent.pos[1:2]..., result_pos), model)
            break
            ## return
        end
        # don't need an else clause, since everything going inside the if clause will break
        # or continue

        # distance left till next node
        dist_left = road_length(agent.pos, model) - agent.pos[3]
        if dist_left < distance # can overshoot
            distance -= dist_left   # leftover distance
            node_a = pop!(osmpath.route)    # remove the node we just reached
            if isempty(osmpath.route)
                # this was the last node, so either we reached the end or dest is on an outgoing road
                if osmpath.dest[1] == osmpath.dest[2]   # we reached the end
                    if osmpath.has_to_return    # need to return from here
                        # empty return route, so reverse along same edge
                        if isempty(osmpath.return_route)
                            move_agent!(agent, (dest[1], agent.pos[1], 0.0), model)
                            osmpath = OpenStreetMapPath(
                                osmpath.return_route,
                                osmpath.dest,
                                get_reverse_direction(osmpath.start, model),
                                Int[],
                                false,
                            )
                            break
                            ## return
                        end
                        osmpath = OpenStreetMapPath(
                            osmpath.return_route,
                            osmpath.dest,
                            osmpath.start,
                            Int[],
                            false,
                        )
                        # next node on return path
                        node_b = osmpath.route[end]
                        # set to move along reverse path
                        move_agent!(agent, (node_a, node_b, 0.0), model)
                        # move rest of distance along return route
                        ## return Agents.move_along_route!(agent, model, distance)
                        continue
                    end
                    # move to end
                    move_agent!(agent, osmpath.dest, model)
                    # remove route so agent is marked as stationary
                    delete!(model.space.routes, agent.id)
                    ## return
                    break
                end

                # destination is on an outgoing road from this last waypoint
                # move to beginning of this road
                move_agent!(agent, (osmpath.dest[1:2]..., 0.0), model)
                # move rest of distance to destination
                ## return Agents.move_along_route!(agent, model, distance)
                continue
            end

            # there is a further waypoint
            node_b = osmpath.route[end]
            move_agent!(agent, (node_a, node_b, 0.0), model)
            # move rest of distance to next waypoint
            ## return Agents.move_along_route!(agent, model, distance)
            continue
        end

        # will not overshoot
        result_pos = min(agent.pos[3] + distance, road_length(agent.pos, model))
        move_agent!(agent, (agent.pos[1:2]..., result_pos), model)
        ## return
        break
    end
end

# Nearby positions must be intersections, since edges imply a direction.
# nearby agents/ids can be on an intersection or on a road X m away.
# We cannot simply use nearby_positions to collect nearby ids then.

# Default is searching both backwards and forwards.
# I assume it would be useful to turn off one or the other at some point.
function Agents.nearby_ids(
    pos::Tuple{Int,Int,Float64},
    model::ABM{<:OpenStreetMapSpace},
    distance::Real,
    args...;
    kwargs...
)
    distances = Dict{Int,Float64}()
    queue = Queue{Int}()
    nearby = Int[]

    if pos[1] == pos[2]
        distances[pos[1]] = 0.0
        enqueue!(queue, pos[1])
    else
        dist_1 = pos[3]
        dist_2 = road_length(pos, model) - pos[3]

        if dist_1 <= distance && dist_2 <= distance
            # just add to queue, all IDs on this road will be covered
            distances[pos[1]] = dist_1
            enqueue!(queue, pos[1])
            distances[pos[2]] = dist_2
            enqueue!(queue, pos[2])
        elseif dist_1 <= distance   # && dist_2 > distance
            # BFS covers IDs `distance` away from `pos[1]`, but not those in range
            # `(distance, dist_1 + distance)` away
            distances[pos[2]] = dist_2
            enqueue!(queue, pos[2])
            # push IDs that won't be covered
            for id in forward_ids_on_road(pos[1], pos[2], model)
                dist_1 < model[id].pos[3] <= dist_1 + distance && push!(nearby, id)
            end
            for id in reverse_ids_on_road(pos[1], pos[2], model)
                dist = road_length(pos, model) - model[id].pos[3]
                dist_1 < dist <= dist_1 + distance && push!(nearby, id)
            end
        elseif dist_2 <= distance # && dist_1 > distance
            # BFS covers IDs `distance` away from `pos[2]`, but not those in range
            # `(distance, dist_2 + distance)` away
            distances[pos[2]] = dist_2
            enqueue!(queue, pos[2])
            # push IDs that won't be covered
            for id in forward_ids_on_road(pos[1], pos[2], model)
                dist = road_length(pos, model) - model[id].pos[3]
                dist_2 < dist <= dist_2 + distance && push!(nearby, id)
            end
            for id in reverse_ids_on_road(pos[1], pos[2], model)
                dist_2 < model[id].pos[3] < dist_2 + distance && push!(nearby, id)
            end
        else    # neither node is within `distance` of `pos`, so simply filter IDs on this road
            for id in forward_ids_on_road(pos[1], pos[2], model)
                abs(model[id].pos[3] - dist_1) <= distance && push!(nearby, id)
            end
            for id in reverse_ids_on_road(pos[1], pos[2], model)
                abs(model[id].pos[3] - dist_2) <= distance && push!(nearby, id)
            end
        end
    end

    # NOTE: During BFS, each node is only explored once. From each node, every outgoing and incoming edge is
    # considered and the node on the other end is added to the queue if it is close enough. The edge is explored
    # for IDs by the node with the lower index (to prevent the same edge from being explored twice).
    # If the node on the other end can't be reached, then the current node explores however far it can on
    # this road. If the other node is reached through another path, it takes this into account and only explores
    # the unexplored part of this edge.
    while !isempty(queue)
        node = dequeue!(queue)
        for nb in nearby_positions(node, model; neighbor_type = :all)
            rd_len = road_length(node, nb, model)
            if rd_len == 0.0 || rd_len == Inf
                rd_len = road_length(nb, node, model)
            end

            if rd_len <= distance - distances[node]  # can reach pos_2 from this node
                if !haskey(distances, nb) # mark for exploration if not visited
                    distances[nb] = distances[node] + rd_len
                    enqueue!(queue, nb)
                end
                if node < nb # road is explored by smaller indexed node
                    append!(nearby, ids_on_road(node, nb, model))
                end
            else
                # cannot reach pos_2 from this node
                dist_to_explore = distance - distances[node]
                if haskey(distances, nb)
                    # part of it is already explored, so only explore remaining part
                    dist_to_explore = max(min(dist_to_explore, rd_len - distances[nb]), 0.0)
                end
                for id in forward_ids_on_road(node, nb, model)
                    model[id].pos[3] <= dist_to_explore && push!(nearby, id)
                end
                for id in reverse_ids_on_road(node, nb, model)
                    dist = rd_len - model[id].pos[3]
                    dist <= dist_to_explore && push!(nearby, id)
                end
            end
        end
    end

    return nearby
end

forward_ids_on_road(pos_1::Int, pos_2::Int, model::ABM{<:OpenStreetMapSpace}) =
    Iterators.filter(i -> model[i].pos[2] == pos_2, model.space.s[pos_1])

reverse_ids_on_road(pos_1::Int, pos_2::Int, model::ABM{<:OpenStreetMapSpace}) =
    forward_ids_on_road(pos_2, pos_1, model)

ids_on_road(pos_1::Int, pos_2::Int, model::ABM{<:OpenStreetMapSpace}) =
    Iterators.flatten((
        forward_ids_on_road(pos_1, pos_2, model),
        reverse_ids_on_road(pos_1, pos_2, model),
    ))

function Agents.nearby_ids(
    agent::A,
    model::ABM{<:OpenStreetMapSpace,A},
    args...;
    kwargs...
) where {A<:AbstractAgent}
    all = nearby_ids(agent.pos, model, args...; kwargs...)
    filter!(i -> i ≠ agent.id, all)
end

Agents.nearby_positions(pos::Tuple{Int,Int,Float64}, model, args...; kwargs...) =
    nearby_positions(pos[1], model, args...; kwargs...)

function Agents.nearby_positions(
    position::Int,
    model::ABM{<:OpenStreetMapSpace};
    neighbor_type::Symbol = :default
)
    @assert neighbor_type ∈ (:default, :all, :in, :out)
    neighborfn = if neighbor_type == :default
        Graphs.neighbors
    elseif neighbor_type == :in
        Graphs.inneighbors
    elseif neighbor_type == :out
        Graphs.outneighbors
    else
        Graphs.all_neighbors
    end
    Int.(neighborfn(model.space.map.graph, position))
end

end # module OSM

const OpenStreetMapSpace = OSM.OpenStreetMapSpace

const OSMSpace = OSM.OpenStreetMapSpace
