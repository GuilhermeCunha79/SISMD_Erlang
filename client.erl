%%%-------------------------------------------------------------------
%%% @author Guilherme Cunha
%%% @copyright (C) 2025, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 31. May 2025 4:21 PM
%%%-------------------------------------------------------------------
%%% client.erl
-module(client).
-export([start/4, loop/1, simulate_failure/1, get_status/0]).

start(SensorId, Interval, Neighbors, MonitorPid) ->
  Pid = spawn(?MODULE, loop, [#{
    id => SensorId,
    interval => Interval,
    active => true,
    neighbors => Neighbors,
    original_neighbors => Neighbors,
    monitor => MonitorPid,
    registered => false,
    pending_data => [],
    direct_link => lists:member(1, Neighbors),
    data_counter => 0
  }]),
  SensorName = list_to_atom("sensor_" ++ integer_to_list(SensorId)),
  register(SensorName, Pid),
  global:register_name(SensorName, Pid),

  case lists:member(1, Neighbors) of
    true ->
      case global:whereis_name(central_server) of
        undefined -> io:format("Sensor ~p: servidor não encontrado~n", [SensorId]);
        ServerPid -> ServerPid ! {register, SensorId, Pid, Neighbors}
      end;
    false ->
      io:format("Sensor ~p: sem ligação direta ao servidor~n", [SensorId]),
      Pid ! registered
  end,

  io:format("Sensor ~p iniciado~n", [SensorId]),
  Pid.

loop(State = #{
  registered := Registered, id := SensorId, interval := Interval, active := Active,
  neighbors := Neighbors, original_neighbors := OriginalNeighbors,
  monitor := MonitorPid, pending_data := Pending, direct_link := Direct,
  data_counter := Counter
}) ->
  receive
    registered ->
      io:format("Sensor ~p registrado no servidor~n", [SensorId]),
      timer:send_interval(Interval, self(), collect),
      timer:send_interval(5000, self(), check_server),
      timer:send_interval(3000, self(), retry_pending),
      loop(State#{registered => true});

    check_server ->
      if
        Registered =:= false, Direct ->
          case global:whereis_name(central_server) of
            undefined -> loop(State);
            Pid when is_pid(Pid) ->
              io:format("Sensor ~p tentando registrar novamente~n", [SensorId]),
              Pid ! {register, SensorId, self(), OriginalNeighbors},
              loop(State)
          end;
        true -> loop(State)
      end;

    collect when Active ->
      DataId = Counter + 1,
      Data = generate_data(),
      io:format("Sensor ~p coletou dados (id ~p): ~p~n", [SensorId, DataId, Data]),
      case Direct of
        true ->
          case global:whereis_name(central_server) of
            undefined ->
              io:format("Sensor ~p: servidor inativo, relay via vizinhos~n", [SensorId]),
              lists:foreach(fun(N) -> send_if_alive(N, SensorId, DataId, Data, [SensorId]) end, Neighbors),
              loop(State#{pending_data => [{SensorId, DataId, Data} | Pending], data_counter => DataId});
            Pid ->
              send_data(Pid, SensorId, DataId, Data),
              loop(State#{data_counter => DataId})
          end;
        false ->
          io:format("Sensor ~p: sem ligação direta, relay via vizinhos~n", [SensorId]),
          lists:foreach(fun(N) -> send_if_alive(N, SensorId, DataId, Data, [SensorId]) end, Neighbors),
          loop(State#{data_counter => DataId})
      end;

    retry_pending ->
      case global:whereis_name(central_server) of
        undefined -> loop(State);
        Pid ->
          lists:foreach(fun({SId, DId, Data}) -> send_data(Pid, SId, DId, Data) end, Pending),
          loop(State#{pending_data => []})
      end;

    fail ->
      io:format("Sensor ~p simulando falha~n", [SensorId]),
      notify_central_failed(global:whereis_name(central_server), SensorId),
      monitor:notify_failure(MonitorPid, SensorId),
      loop(State#{active => false});

    recover ->
      io:format("Sensor ~p recuperando~n", [SensorId]),
      case Direct of
        true -> notify_central_register(global:whereis_name(central_server), SensorId, self(), OriginalNeighbors);
        false -> ok
      end,
      monitor:notify_recovery(MonitorPid, SensorId, OriginalNeighbors),
      loop(State#{active => true, neighbors => OriginalNeighbors});

    stop ->
      io:format("Sensor ~p parado~n", [SensorId]);

    {neighbor_failed, FailedNeighbor} ->
      io:format("Sensor ~p removendo vizinho falhado ~p~n", [SensorId, FailedNeighbor]),
      NewNeighbors = lists:filter(fun(N) -> N =/= FailedNeighbor end, Neighbors),
      loop(State#{neighbors => NewNeighbors});

    {relay, FromSensorId, DataId, Data, Seen} when Active ->
      io:format("Sensor ~p RECEBEU relay do Sensor ~p (id ~p): ~p~n", [SensorId, FromSensorId, DataId, Data]),
      case Direct of
        true ->
          case global:whereis_name(central_server) of
            undefined ->
              io:format("Sensor ~p: servidor inativo, repassando relay para vizinhos~n", [SensorId]),
              NextNeighbors = lists:filter(fun(N) -> not lists:member(N, Seen) end, Neighbors),
              lists:foreach(fun(N) ->
                send_if_alive(N, FromSensorId, DataId, Data, [SensorId | Seen])
                            end, NextNeighbors),
              loop(State#{pending_data => [{FromSensorId, DataId, Data} | Pending]});
            Pid ->
              send_data(Pid, FromSensorId, DataId, Data),
              loop(State)
          end;
        false ->
          io:format("Sensor ~p: relay sem ligação direta, repassando~n", [SensorId]),
          NextNeighbors = lists:filter(fun(N) -> not lists:member(N, Seen) end, Neighbors),
          lists:foreach(fun(N) ->
            send_if_alive(N, FromSensorId, DataId, Data, [SensorId | Seen])
                        end, NextNeighbors),
          loop(State)
      end;

    {relay, _FromSensorId, _DataId, _Data, _Seen} ->
      io:format("Sensor ~p inativo, ignorando relay~n", [SensorId]),
      loop(State);

    _Other -> loop(State)
  end.

send_data(Pid, SensorId, DataId, Data) ->
  io:format("Sensor ~p: enviando dados (id ~p) para o servidor~n", [SensorId, DataId]),
  Pid ! {data, SensorId, DataId, Data}.

send_if_alive(NeighborId, OriginalSensorId, DataId, Data, Seen) ->
  case lists:member(NeighborId, Seen) of
    true -> ok;
    false ->
      SensorName = list_to_atom("sensor_" ++ integer_to_list(NeighborId)),
      Pid = global:whereis_name(SensorName),
      case Pid of
        undefined -> ok;
        _ ->
          case node(Pid) == node() of
            true ->
              case is_process_alive(Pid) of
                true -> Pid ! {relay, OriginalSensorId, DataId, Data, Seen};
                false -> ok
              end;
            false ->
              Pid ! {relay, OriginalSensorId, DataId, Data, Seen},
              ok
          end
      end
  end.

notify_central_failed(undefined, _SensorId) -> ok;
notify_central_failed(Pid, SensorId) -> Pid ! {failed, SensorId}.

notify_central_register(undefined, _SensorId, _Pid, _Neighbors) -> ok;
notify_central_register(Pid, SensorId, PidSender, Neighbors) ->
  Pid ! {register, SensorId, PidSender, Neighbors}.

generate_data() ->
  #{temp => 20 + rand:uniform(10), humid => 40 + rand:uniform(20)}.

simulate_failure(SensorId) ->
  SensorName = list_to_atom("sensor_" ++ integer_to_list(SensorId)),
  case global:whereis_name(SensorName) of
    undefined -> io:format("Sensor ~p não encontrado~n", [SensorId]);
    Pid -> Pid ! fail
  end.

get_status() ->
  case global:whereis_name(central_server) of
    undefined -> io:format("Servidor central não está ativo~n");
    Pid ->
      Pid ! {status, self()},
      receive
        {status_reply, State} ->
          Sensors = maps:get(sensors, State, #{}),
          Data = maps:get(data, State, []),
          io:format("Sensores ativos: ~p~n", [maps:size(Sensors)]),
          io:format("Dados recebidos: ~p~n", [length(Data)])
      after 5000 -> io:format("Timeout aguardando resposta do servidor~n")
      end
  end.