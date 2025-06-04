%%%-------------------------------------------------------------------
%%% @author Guilherme Cunha
%%% @copyright (C) 2025, ISEP
%%% @doc
%%%
%%% @end
%%% Created : 31. May 2025 4:21 PM
%%%-------------------------------------------------------------------
-module(server).
-export([start/1, loop/1, stop/1]).

start(MonitorHost) ->
  Sensors = #{},
  Data = [],
  ReceivedIds = sets:new(),
  Pid = spawn(?MODULE, loop, [#{monitor_host => MonitorHost, sensors => Sensors, data => Data, received_ids => ReceivedIds}]),
  register(central_server, Pid),

  io:format("Central server started (monitor at ~p)~n", [MonitorHost]),
  Pid.

loop(State = #{monitor_host := MonitorHost, sensors := Sensors, data := Data, received_ids := ReceivedIds}) ->
  receive
    {register, SensorId, SensorPid, Neighbors} ->
      {monitor, MonitorHost} ! {register, SensorId, SensorPid, Neighbors},
      NewSensors = maps:put(SensorId, SensorPid, Sensors),
      SensorPid ! registered,
      loop(State#{sensors => NewSensors});

    {failed, SensorId} ->
      io:format("Server received failure from sensor ~p~n", [SensorId]),
      NewSensors = maps:remove(SensorId, Sensors),
      {monitor, MonitorHost} ! {failure_report, SensorId},
      loop(State#{sensors => NewSensors});

    {data, SensorId, UniqueId, DataValue} ->
      Key = {SensorId, UniqueId},
      case sets:is_element(Key, ReceivedIds) of
        true ->
          io:format("Server ignored duplicate data from sensor ~p with ID=~p~n", [SensorId, UniqueId]),
          loop(State);
        false ->
          io:format("Server received data from sensor ~p with ID=~p: ~p~n", [SensorId, UniqueId, DataValue]),
          NewReceivedIds = sets:add_element(Key, ReceivedIds),
          NewData = [{SensorId, UniqueId, DataValue, erlang:timestamp()} | Data],
          loop(State#{data => NewData, received_ids => NewReceivedIds})
      end;

    {status, From} ->
      From ! {status_reply, State},
      loop(State);

    {stop, From} ->
      io:format("Server stopped~n"),
      From ! stopped,
      ok;

    _Other ->
      loop(State)
  end.

stop(ServerPid) ->
  ServerPid ! {stop, self()},
  receive
    stopped -> io:format("Server successfully terminated~n")
  after 5000 -> io:format("Timeout waiting for server shutdown~n")
  end.