%%%-------------------------------------------------------------------
%%% @author Guilherme Cunha
%%% @copyright (C) 2025, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 31. May 2025 4:21 PM
%%%-------------------------------------------------------------------
-module(server).
-export([start/0, loop/1, stop/1]).

start() ->
  MonitorPid = monitor:start(),
  Sensors = #{},
  Data = [],
  ReceivedIds = sets:new(),
  Pid = spawn(?MODULE, loop, [#{monitor => MonitorPid, sensors => Sensors, data => Data, received_ids => ReceivedIds}]),
  register(central_server, Pid),
  global:register_name(central_server, Pid),
  register(monitor, MonitorPid),
  global:register_name(monitor, MonitorPid),
  Pid.

loop(State = #{
  monitor := MonitorPid,
  sensors := Sensors,
  data := Data,
  received_ids := ReceivedIds
}) ->
  receive
    {register, SensorId, SensorPid, Neighbors} ->
      monitor:register_sensor(MonitorPid, SensorId, SensorPid, Neighbors),
      NewSensors = maps:put(SensorId, SensorPid, Sensors),
      SensorPid ! registered,
      loop(State#{sensors => NewSensors});

    {failed, SensorId} ->
      io:format("Servidor recebeu falha do sensor ~p~n", [SensorId]),
      NewSensors = maps:remove(SensorId, Sensors),
      monitor:notify_failure(MonitorPid, SensorId),
      loop(State#{sensors => NewSensors});

    {data, SensorId, UniqueId, DataValue} ->
      Key = {SensorId, UniqueId},
      case sets:is_element(Key, ReceivedIds) of
        true ->
          %% Já recebeu este dado, ignorar
          io:format("Servidor ignorou dado duplicado do sensor ~p com ID=~p~n", [SensorId, UniqueId]),
          loop(State);
        false ->
          %% Novo dado, armazenar e registrar ID para evitar duplicação futura
          io:format("Servidor recebeu dados do sensor ~p com ID=~p: ~p~n", [SensorId, UniqueId, DataValue]),
          NewReceivedIds = sets:add_element(Key, ReceivedIds),
          NewData = [{SensorId, UniqueId, DataValue, erlang:timestamp()} | Data],
          loop(State#{data => NewData, received_ids => NewReceivedIds})
      end;

    {status, From} ->
      From ! {status_reply, State},
      loop(State);

    {stop, From} ->
      io:format("Servidor parado~n"),
      From ! stopped,
      ok;

    _Other ->
      loop(State)
  end.

stop(ServerPid) ->
  ServerPid ! {stop, self()},
  receive
    stopped -> io:format("Servidor finalizado com sucesso~n")
  after 5000 -> io:format("Timeout aguardando parada do servidor~n")
  end.