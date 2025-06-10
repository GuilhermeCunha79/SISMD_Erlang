%%%-------------------------------------------------------------------
%%% @author Guilherme Cunha
%%% @copyright (C) 2025, ISEP
%%% @doc
%%%
%%% @end
%%% Created : 31. May 2025 4:21 PM
%%%-------------------------------------------------------------------
-module(client).
-export([start/5, loop/1, simulate_failure/1, simulate_recovery/1]).

start(SensorId, Interval, Neighbors, ServerHost, MonitorHost) ->
  State = #{id => SensorId, interval => Interval, active => true, neighbors => Neighbors,
    original_neighbors => Neighbors, server_host => ServerHost, monitor_host => MonitorHost,
    registered => false, pending_data => [], direct_link => lists:member(0, Neighbors),
    data_counter => 0, timers_started => false, timer_refs => []},
  Pid = spawn(?MODULE, loop, [State]),
  SensorName = list_to_atom("sensor_" ++ integer_to_list(SensorId)),
  register(SensorName, Pid),
  global:register_name(SensorName, Pid),

  timer:send_after(1000, Pid, setup_neighbors),

  maybe_register(SensorId, Pid, Neighbors, ServerHost, MonitorHost),
  io:format("Sensor ~p started~n", [SensorId]),
  Pid.

loop(State = #{registered := Registered, id := SensorId, interval := Interval, active := Active,
  neighbors := Neighbors, original_neighbors := OriginalNeighbors, server_host := ServerHost,
  monitor_host := MonitorHost, pending_data := Pending, direct_link := Direct,
  data_counter := Counter, timers_started := TimersStarted, timer_refs := TimerRefs}) ->
  receive
    registered when not TimersStarted ->
      io:format("Sensor ~p registered with the server~n", [SensorId]),
      [timer:cancel(Ref) || Ref <- TimerRefs],
      {ok, CollectRef} = timer:send_interval(Interval, self(), collect),
      {ok, CheckRef} = timer:send_interval(5000, self(), check_server),
      {ok, RetryRef} = timer:send_interval(3000, self(), retry_pending),
      NewTimerRefs = [CollectRef, CheckRef, RetryRef],
      loop(State#{registered => true, timers_started => true, timer_refs => NewTimerRefs});

    registered when TimersStarted ->
      loop(State#{registered => true});

    setup_neighbors ->
      io:format("Sensor ~p: setting up neighbor relationships~n", [SensorId]),
      notify_neighbors(SensorId, Neighbors, neighbor_added),
      check_reverse_neighbors(SensorId),
      loop(State);

    check_server when not Registered andalso Direct ->
      case is_service_alive(ServerHost, central_server) of
        true ->
          io:format("Sensor ~p attempting to re-register~n", [SensorId]),
          {central_server, ServerHost} ! {register, SensorId, self(), OriginalNeighbors};
        false -> ok
      end,
      loop(State);

    check_server ->
      loop(State);

    collect when Active ->
      DataId = Counter + 1,
      Data = generate_data(),
      io:format("Sensor ~p collected data (id ~p): ~p~n", [SensorId, DataId, Data]),
      {Success, UpdatedNeighbors} = send_data(SensorId, DataId, Data, Neighbors, Direct, ServerHost, []),
      NewPending = case Success of
                     false ->
                       case is_data_pending(Pending, SensorId, DataId) of
                         true ->
                           io:format("Sensor ~p: data ~p already in pending list~n", [SensorId, DataId]),
                           Pending;
                         false ->
                           io:format("Sensor ~p: adding data ~p to pending list~n", [SensorId, DataId]),
                           [{SensorId, DataId, Data, 0} | Pending]
                       end;
                     true -> Pending
                   end,
      loop(State#{data_counter => DataId, pending_data => NewPending, neighbors => UpdatedNeighbors});

    retry_pending ->
      {NewPending, UpdatedNeighbors} = retry_pending_data(Pending, ServerHost, Neighbors, Direct, SensorId, MonitorHost),
      loop(State#{pending_data => NewPending, neighbors => UpdatedNeighbors});

    fail ->
      io:format("Sensor ~p simulating failure~n", [SensorId]),
      [timer:cancel(Ref) || Ref <- TimerRefs],
      notify_neighbors(SensorId, OriginalNeighbors, neighbor_failed),
      notify_service(ServerHost, central_server, {failed, SensorId}),
      notify_service(MonitorHost, monitor, {failure_report, SensorId}),
      loop(State#{active => false, timers_started => false, timer_refs => []});

    recover ->
      io:format("Sensor ~p recovering~n", [SensorId]),
      notify_neighbors(SensorId, OriginalNeighbors, neighbor_recovered),
      case maps:get(direct_link, State) of
        true -> notify_service(ServerHost, central_server, {register, SensorId, self(), OriginalNeighbors});
        false -> ok
      end,
      notify_service(MonitorHost, monitor, {recovery_report, SensorId, OriginalNeighbors}),
      {ok, CollectRef} = timer:send_interval(Interval, self(), collect),
      {ok, CheckRef} = timer:send_interval(5000, self(), check_server),
      {ok, RetryRef} = timer:send_interval(3000, self(), retry_pending),
      NewTimerRefs = [CollectRef, CheckRef, RetryRef],
      loop(State#{active => true, neighbors => OriginalNeighbors, timers_started => true, timer_refs => NewTimerRefs});

    stop ->
      io:format("Sensor ~p stopped~n", [SensorId]),
      [timer:cancel(Ref) || Ref <- TimerRefs];

    {neighbor_added, NewNeighborId} ->
      io:format("Sensor ~p: received notification that sensor ~p joined as neighbor~n", [SensorId, NewNeighborId]),
      NewNeighbors = ensure_in_list(NewNeighborId, Neighbors),
      NewOriginalNeighbors = ensure_in_list(NewNeighborId, OriginalNeighbors),
      loop(State#{neighbors => NewNeighbors, original_neighbors => NewOriginalNeighbors});

    {check_if_neighbor, NewSensorId} ->
      case lists:member(NewSensorId, OriginalNeighbors) of
        true ->
          notify_sensor(NewSensorId, {neighbor_added, SensorId}),
          loop(State#{neighbors => ensure_in_list(NewSensorId, Neighbors)});
        false -> loop(State)
      end;

    {neighbor_failed, FailedSensorId} ->
      io:format("Sensor ~p: received notification that neighbor ~p failed~n", [SensorId, FailedSensorId]),
      loop(State#{neighbors => lists:delete(FailedSensorId, Neighbors)});

    {neighbor_recovered, RecoveredSensorId} ->
      io:format("Sensor ~p: received notification that neighbor ~p recovered~n", [SensorId, RecoveredSensorId]),
      NewNeighbors = case lists:member(RecoveredSensorId, OriginalNeighbors) of
                       true -> ensure_in_list(RecoveredSensorId, Neighbors);
                       false -> Neighbors
                     end,
      loop(State#{neighbors => NewNeighbors});

    {relay, OriginalSensorId, DataId, Data, Seen} when Active ->
      io:format("Sensor ~p RECEIVED relay from Sensor ~p (id ~p): ~p~n",
        [SensorId, OriginalSensorId, DataId, Data]),

      case Direct orelse has_different_neighbors(SensorId, Neighbors, Seen) of
        true ->
          {Success, UpdatedNeighbors} = send_data(OriginalSensorId, DataId, Data, Neighbors, Direct, ServerHost, [SensorId | Seen]),
          NewPending = case Success of
                         false ->
                           case is_data_pending(Pending, OriginalSensorId, DataId) of
                             true -> Pending;
                             false -> [{OriginalSensorId, DataId, Data, 0} | Pending]
                           end;
                         true -> Pending
                       end,
          loop(State#{pending_data => NewPending, neighbors => UpdatedNeighbors});
        false ->
          io:format("Sensor ~p: ignoring relay - no useful path to forward data~n", [SensorId]),
          loop(State)
      end;

    {relay, _FromSensorId, _DataId, _Data, _Seen} ->
      io:format("Sensor ~p inactive, ignoring relay~n", [SensorId]),
      loop(State);

    _Other ->
      io:format("Sensor ~p received unknown message: ~p~n", [SensorId, _Other]),
      loop(State)
  end.

maybe_register(SensorId, Pid, Neighbors, ServerHost, MonitorHost) ->
  case lists:member(0, Neighbors) of
    true ->
      case is_service_alive(ServerHost, central_server) of
        true ->
          {central_server, ServerHost} ! {register, SensorId, Pid, Neighbors},
          io:format("Sensor ~p: sent registration to server~n", [SensorId]);
        false ->
          io:format("Sensor ~p: cannot connect to server at ~p~n", [SensorId, ServerHost])
      end;
    false ->
      io:format("Sensor ~p: no direct link to the server~n", [SensorId])
  end,
  Pid ! registered,

  case is_service_alive(MonitorHost, monitor) of
    true ->
      {monitor, MonitorHost} ! {register, SensorId, Pid, Neighbors},
      io:format("Sensor ~p registered with monitor~n", [SensorId]);
    false ->
      io:format("Sensor ~p: cannot connect to monitor at ~p~n", [SensorId, MonitorHost])
  end.

is_service_alive(Host, Service) ->
  case rpc:call(Host, erlang, whereis, [Service]) of
    {badrpc, _} -> false;
    undefined -> false;
    _ -> true
  end.

notify_service(Host, Service, Msg) ->
  case is_service_alive(Host, Service) of
    true -> {Service, Host} ! Msg;
    false -> ok
  end.

notify_sensor(SensorId, Msg) ->
  SensorName = list_to_atom("sensor_" ++ integer_to_list(SensorId)),
  case global:whereis_name(SensorName) of
    undefined -> ok;
    Pid -> Pid ! Msg
  end.

notify_neighbors(SensorId, Neighbors, MsgType) ->
  lists:foreach(fun(0) -> ok;
                  (NeighborId) -> notify_sensor(NeighborId, {MsgType, SensorId})
                end, Neighbors).

check_reverse_neighbors(SensorId) ->
  lists:foreach(fun(Name) ->
    case atom_to_list(Name) of
      "sensor_" ++ IdStr ->
        try list_to_integer(IdStr) of
          OtherId when OtherId =/= SensorId -> notify_sensor(OtherId, {check_if_neighbor, SensorId});
          _ -> ok
        catch _:_ -> ok
        end;
      _ -> ok
    end
                end, global:registered_names()).

send_data(OriginalSensorId, DataId, Data, Neighbors, Direct, ServerHost, Seen) ->
  case Direct andalso is_service_alive(ServerHost, central_server) of
    true ->
      {central_server, ServerHost} ! {data, OriginalSensorId, DataId, Data},
      io:format("Sensor ~p sent data ~p directly to server~n", [OriginalSensorId, DataId]),
      {true, Neighbors};
    false ->
      ActiveNeighbors = [N || N <- Neighbors, N =/= 0, not lists:member(N, Seen), is_neighbor_active(N)],

      case ActiveNeighbors of
        [] ->
          io:format("Sensor ~p: no active neighbors to relay data ~p (seen: ~p)~n", [OriginalSensorId, DataId, Seen]),
          {false, Neighbors};
        _ ->
          lists:foreach(fun(N) ->
            io:format("Sensor ~p RELAYING data ~p from Sensor ~p to neighbor Sensor ~p~n", [OriginalSensorId, DataId, OriginalSensorId, N]),
            notify_sensor(N, {relay, OriginalSensorId, DataId, Data, [OriginalSensorId | Seen]})
                        end, ActiveNeighbors),
          Failed = [N || N <- Neighbors, N =/= 0, not is_neighbor_active(N)],
          {true, Neighbors -- Failed}
      end
  end.

retry_pending_data(Pending, ServerHost, Neighbors, Direct, SensorId, MonitorHost) ->
  case Pending of
    [] -> {[], Neighbors};
    _ ->
      lists:foldl(
        fun({OrigSensorId, DataId, Data, Attempts}, {AccPending, AccNeighbors}) ->
          case is_data_pending(AccPending, OrigSensorId, DataId) of
            true ->
              io:format("Sensor ~p: skipping duplicate data ~p from sensor ~p~n", [SensorId, DataId, OrigSensorId]),
              {AccPending, AccNeighbors};
            false ->
              io:format("Sensor ~p retrying data ~p from sensor ~p (attempt ~p)~n",
                [SensorId, DataId, OrigSensorId, Attempts + 1]),
              {Success, UpdatedNeighbors} = send_data(OrigSensorId, DataId, Data, AccNeighbors, Direct, ServerHost, []),
              case Success of
                true -> {AccPending, UpdatedNeighbors};
                false when Attempts < 50 ->
                  {[{OrigSensorId, DataId, Data, Attempts + 1} | AccPending], UpdatedNeighbors};
                false ->
                  io:format("Sensor ~p: data ~p from sensor ~p lost after 50 attempts~n", [SensorId, DataId, OrigSensorId]),
                  notify_service(MonitorHost, monitor, {data_lost, OrigSensorId, DataId}),
                  {AccPending, UpdatedNeighbors}
              end
          end
        end,
        {[], Neighbors},
        Pending)
  end.

is_neighbor_active(NeighborId) ->
  SensorName = list_to_atom("sensor_" ++ integer_to_list(NeighborId)),
  case global:whereis_name(SensorName) of
    undefined -> false;
    Pid when node(Pid) == node() -> is_process_alive(Pid);
    Pid ->
      try
        rpc:call(node(Pid), erlang, is_process_alive, [Pid], 1000)
      catch
        _:_ -> false
      end
  end.

ensure_in_list(Item, List) ->
  case lists:member(Item, List) of
    true -> List;
    false -> [Item | List]
  end.

is_data_pending(Pending, SensorId, DataId) ->
  lists:any(fun({SId, DId, _, _}) ->
    SId =:= SensorId andalso DId =:= DataId
            end, Pending).

has_different_neighbors(_SensorId, Neighbors, Seen) ->
  AvailableNeighbors = [N || N <- Neighbors, N =/= 0, not lists:member(N, Seen)],
  length(AvailableNeighbors) > 0.

generate_data() ->
  #{temp => 20 + rand:uniform(10), humid => 40 + rand:uniform(20)}.

simulate_failure(SensorId) ->
  notify_sensor(SensorId, fail).

simulate_recovery(SensorId) ->
  notify_sensor(SensorId, recover).