%%%-------------------------------------------------------------------
%%% @author Guilherme Cunha
%%% @copyright (C) 2025, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 31. May 2025 7:35 PM
%%%-------------------------------------------------------------------
-module(monitor).
-export([start/0, loop/1, register_sensor/4, notify_failure/2, notify_recovery/3]).

start() ->
  spawn(?MODULE, loop, [#{}]).

loop(State) ->
  receive
    {register, SensorId, Pid, Neighbors} ->

      State1 = case maps:find(SensorId, State) of
                 {ok, {_OldPid, OldRef, _OldNeighbors}} ->
                   erlang:demonitor(OldRef, [flush]),
                   maps:remove(SensorId, State);
                 error ->
                   State
               end,

      Ref = erlang:monitor(process, Pid),
      State2 = maps:put(SensorId, {Pid, Ref, Neighbors}, State1),
      io:format("Monitor: sensor ~p registado~n", [SensorId]),
      loop(State2);

    {'DOWN', Ref, process, _Pid, Reason} ->
      case find_sensor_by_ref(Ref, State) of
        {ok, SensorId} ->
          io:format("Monitor: sensor ~p falhou (~p)~n", [SensorId, Reason]),
          {_Pid, _Ref, Neighbors} = maps:get(SensorId, State),
          State1 = maps:remove(SensorId, State),
          notify_all_neighbors_failure(SensorId, State1),
          loop(State1);
        error ->
          loop(State)
      end;

    {failure_report, SensorId} ->
      io:format("Monitor: sensor ~p reportou falha~n", [SensorId]),
      loop(State);

    {recovery_report, SensorId, NewNeighbors} ->
      case maps:find(SensorId, State) of
        {ok, {Pid, Ref, _OldNeighbors}} ->
          NewState = maps:put(SensorId, {Pid, Ref, NewNeighbors}, State),
          io:format("Monitor: sensor ~p recuperou com vizinhos ~p~n", [SensorId, NewNeighbors]),
          loop(NewState);
        error ->
          io:format("Monitor: tentativa de recuperação de sensor não registado ~p~n", [SensorId]),
          loop(State)
      end;

    {get_state, From} ->
      From ! {monitor_state, State},
      loop(State);

    stop ->
      io:format("Monitor parado~n"),
      ok;

    _Other ->
      io:format("Monitor: mensagem desconhecida ~p~n", [_Other]),
      loop(State)
  end.

find_sensor_by_ref(Ref, State) ->
  maps:fold(
    fun(SensorId, {_Pid, MonRef, _Neighbors}, Acc) ->
      case MonRef =:= Ref of
        true -> {ok, SensorId};
        false -> Acc
      end
    end, error, State).

notify_all_neighbors_failure(FailedSensorId, State) ->
  maps:fold(
    fun(_Id, {Pid, _Ref, Neighbors}, _Acc) ->
      case lists:member(FailedSensorId, Neighbors) of
        true ->
          catch Pid ! {neighbor_failed, FailedSensorId};
        false ->
          ok
      end
    end, ok, State).

register_sensor(MonitorPid, SensorId, SensorPid, Neighbors) ->
  MonitorPid ! {register, SensorId, SensorPid, Neighbors}.

notify_failure(MonitorPid, SensorId) ->
  MonitorPid ! {failure_report, SensorId}.

notify_recovery(MonitorPid, SensorId, Neighbors) ->
  MonitorPid ! {recovery_report, SensorId, Neighbors}.