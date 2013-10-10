%%% @doc MySql repository implementation.
%%%
%%% Copyright 2012 Marcelo Gornstein &lt;marcelog@@gmail.com&gt;
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%% @end
%%% @copyright Marcelo Gornstein <marcelog@gmail.com>
%%% @author Marcelo Gornstein <marcelog@gmail.com>
%%%
-module(sumo_repo_mysql).
-author("Marcelo Gornstein <marcelog@gmail.com>").
-github("https://github.com/marcelog").
-homepage("http://marcelog.github.com/").
-license("Apache License 2.0").

-include_lib("include/sumo_doc.hrl").
-include_lib("emysql/include/emysql.hrl").

-behavior(sumo_repo).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Exports.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Public API.
-export([init/1]).
-export([create_schema/2]).
-export([persist/2]).
-export([delete/3, delete_by/3, delete_all/2]).
-export([prepare/3, execute/2, execute/3]).
-export([find_all/2, find_all/5, find_by/3, find_by/5]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Types.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-record(state, {pool:: pid()}).
-type state() :: #state{}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% External API.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
persist(#sumo_doc{name=DocName}=Doc, State) ->
  % Set the real id, replacing undefined by 0 so it is autogenerated
  IdField = sumo:field_name(sumo:get_id_field(DocName)),
  NewId = case sumo:get_field(IdField, Doc) of
    undefined -> 0;
    Id -> Id
  end,
  NewDoc = sumo:set_field(IdField, NewId, Doc),
  % Needed because the queries will carry different number of arguments.
  Statement = case NewId of
    0 -> insert;
    NewId -> update
  end,
  StatementName = prepare(DocName, Statement, fun() ->
    [ColumnDqls, ColumnSqls] = lists:foldl(
      fun({Name, _Value}, [Dqls, Sqls]) ->
        Dql = [escape(atom_to_list(Name))],
        Sql = "?",
        [[Dql|Dqls], [Sql|Sqls]]
      end,
      [[], []],
      NewDoc#sumo_doc.fields
    ),
    [
      "INSERT INTO ", escape(atom_to_list(DocName)),
      " (", string:join(ColumnDqls, ","), ")",
      " VALUES (", string:join(ColumnSqls, ","), ")",
      " ON DUPLICATE KEY UPDATE ",
      string:join([[ColumnName, "=?"] || ColumnName <- ColumnDqls], ",")
    ]
  end),

  ColumnValues = lists:reverse([V || {_K, V} <- NewDoc#sumo_doc.fields]),
  case execute(StatementName, lists:append(ColumnValues, ColumnValues), State) of
    #ok_packet{insert_id = InsertId} ->
      % XXX TODO darle una vuelta mas de rosca
      % para el manejo general de cuando te devuelve el primary key
      % considerar el caso cuando la primary key (campo id) no es integer
      % tenes que poner unique index en lugar de primary key
      % la mejor solucion es que el PK siempre sea un integer, como hace mongo
      LastId = case InsertId of
        0 -> NewId;
        I -> I
      end,
      IdField = sumo:field_name(sumo:get_id_field(DocName)),
      {ok, sumo:set_field(IdField, LastId, Doc), State};
    Error -> evaluate_execute_result(Error, State)
  end.

delete(DocName, Id, State) ->
  StatementName = prepare(DocName, delete, fun() -> [
    "DELETE FROM ", escape(atom_to_list(DocName)),
    " WHERE ", escape(atom_to_list(sumo:field_name(sumo:get_id_field(DocName)))),
    "=? LIMIT 1"
  ] end),
  case execute(StatementName, [Id], State) of
    #ok_packet{affected_rows = NumRows} -> {ok, NumRows > 0, State};
    Error -> evaluate_execute_result(Error, State)
  end.

delete_by(DocName, Conditions, State) ->
  PreStatementName = list_to_atom("delete_by_" ++ string:join(
    [atom_to_list(K) || {K, _V} <- Conditions],
    "_"
  )),
  StatementFun =
    fun() ->
      [ "DELETE FROM ", escape(atom_to_list(DocName)), " WHERE ",
        string:join(
          [  [escape(atom_to_list(K)), "=?"]
          || {K, _V} <- Conditions
          ],
          " AND "
          )
      ]
    end,
  StatementName = prepare(DocName, PreStatementName, StatementFun),
  Values = [V || {_K, V} <- Conditions],
  case execute(StatementName, Values, State) of
    #ok_packet{affected_rows = NumRows} -> {ok, NumRows, State};
    Error -> evaluate_execute_result(Error, State)
  end.

delete_all(DocName, State) ->
  StatementName = prepare(DocName, delete_all, fun() ->
    ["DELETE FROM ", escape(atom_to_list(DocName))]
  end),
  case execute(StatementName, State) of
    #ok_packet{affected_rows = NumRows} -> {ok, NumRows, State};
    Error -> evaluate_execute_result(Error, State)
  end.

find_all(DocName, State) ->
  find_all(DocName, undefined, 0, 0, State).

find_all(DocName, OrderField, Limit, Offset, State) ->
  % Select * is not good...
  Sql0 = ["SELECT * FROM ", escape(atom_to_list(DocName)), " "],
  {Sql1, ExecArgs1} =
    case OrderField of
      undefined -> {Sql0, []};
      _         -> {[Sql0, " ORDER BY ? "], [atom_to_list(OrderField)]}
    end,
  {Sql2, ExecArgs2} =
    case Limit of
      0     -> {Sql1, ExecArgs1};
      Limit -> {[Sql1, " LIMIT ?,?"], lists:append(ExecArgs1, [Offset, Limit])}
    end,

  StatementName = prepare(DocName, find_all, fun() -> Sql2 end),

  case execute(StatementName, ExecArgs2, State) of
    #result_packet{rows = Rows, field_list = Fields} ->
      Docs   = lists:foldl(
        fun(Row, DocList) ->
          NewDoc = lists:foldl(
            fun(Field, [Doc,N]) ->
              FieldRecord = lists:nth(N, Fields),
              FieldName = list_to_atom(binary_to_list(FieldRecord#field.name)),
              [sumo:set_field(FieldName, Field, Doc), N+1]
            end,
            [sumo:new_doc(DocName), 1],
            Row
          ),
          [hd(NewDoc)|DocList]
        end,
        [],
        Rows
      ),
      {ok, lists:reverse(Docs), State};
    Error -> evaluate_execute_result(Error, State)
  end.

%% XXX We should have a DSL here, to allow querying in a known language
%% to be translated by each driver into its own.
find_by(DocName, Conditions, Limit, Offset, State) ->
  {PreStatementName, DocFields, Values} = lists:foldl(
    fun({K, V}, {SName, Fs, Vs}) ->
      {SName ++ "_" ++ atom_to_list(K), [K|Fs], [V|Vs]}
    end,
    {"", [], []},
    Conditions
  ),
  StatementName = prepare(DocName, list_to_atom("find_by" ++ PreStatementName), fun() ->
    Sqls = [[escape(atom_to_list(K)), "=?"] || K <- DocFields],
    % Select * is not good..
    Sql1 =[
      "SELECT * FROM ", escape(atom_to_list(DocName)),
      " WHERE ", string:join(Sqls, " AND ")
    ],
    Sql2 = case Limit of
      0 -> Sql1;
      _ -> [Sql1|[" LIMIT ?,?"]]
    end,
    Sql2
  end),
  ExecArgs =
    case Limit of
      0 -> Values;
      Limit -> lists:flatten([Values|[Offset, Limit]])
    end,

  case execute(StatementName, ExecArgs, State) of
    #result_packet{rows = Rows, field_list = Fields} ->
      Docs = lists:foldl(
        fun(Row, DocList) ->
          NewDoc = lists:foldl(
            fun(Field, [Doc,N]) ->
              FieldRecord = lists:nth(N, Fields),
              FieldName = list_to_atom(binary_to_list(FieldRecord#field.name)),
              [sumo:set_field(FieldName, Field, Doc), N+1]
            end,
            [sumo:new_doc(DocName), 1],
            Row
          ),
          [hd(NewDoc)|DocList]
        end,
        [],
        Rows
      ),
      {ok, lists:reverse(Docs), State};
    Error -> evaluate_execute_result(Error, State)
  end.

find_by(DocName, Conditions, State) ->
  find_by(DocName, Conditions, 0, 0, State).

%% XXX: Refactor:
%% Requires {length, X} to be the first field attribute in order to form the
%% correct query. :P
%% If no indexes are defined, will put an extra comma :P
%% Maybe it would be better to just use ALTER statements instead of trying to
%% create the schema on the 1st pass. Also, ALTER statements might be better
%% for when we have migrations.
create_schema(#sumo_schema{name=Name, fields=Fields}, State) ->
  FieldsDql = lists:map(fun create_column/1, Fields),
  Indexes = lists:filter(
    fun(T) -> length(T) > 0 end,
    lists:map(fun create_index/1, Fields)
  ),
  Dql = [
    "CREATE TABLE IF NOT EXISTS ", escape(atom_to_list(Name)), " (",
    string:join(FieldsDql, ","), ",", string:join(Indexes, ","),
    ") ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=utf8"
  ],
  case execute(Dql, State) of
    #ok_packet{} -> {ok, State};
    Error -> evaluate_execute_result(Error, State)
  end.

create_column(#sumo_field{name=Name, type=integer, attrs=Attrs}) ->
  [escape(atom_to_list(Name)), " INT(11) ", create_column_options(Attrs)];

create_column(#sumo_field{name=Name, type=float, attrs=Attrs}) ->
  [escape(atom_to_list(Name)), " FLOAT ", create_column_options(Attrs)];

create_column(#sumo_field{name=Name, type=text, attrs=Attrs}) ->
  [escape(atom_to_list(Name)), " TEXT ", create_column_options(Attrs)];

create_column(#sumo_field{name=Name, type=binary, attrs=Attrs}) ->
  [escape(atom_to_list(Name)), " BLOB ", create_column_options(Attrs)];

create_column(#sumo_field{name=Name, type=string, attrs=Attrs}) ->
  [escape(atom_to_list(Name)), " VARCHAR ", create_column_options(Attrs)];

create_column(#sumo_field{name=Name, type=date, attrs=Attrs}) ->
  [escape(atom_to_list(Name)), " DATE ", create_column_options(Attrs)];

create_column(#sumo_field{name=Name, type=datetime, attrs=Attrs}) ->
  [escape(atom_to_list(Name)), " DATETIME ", create_column_options(Attrs)].

create_column_options(Attrs) ->
  lists:filter(fun(T) -> is_list(T) end, lists:map(
    fun(Option) ->
      create_column_option(Option)
    end,
    Attrs
  )).

create_column_option(auto_increment) ->
  ["AUTO_INCREMENT "];

create_column_option(not_null) ->
  [" NOT NULL "];

create_column_option({length, X}) ->
  ["(", integer_to_list(X), ") "];

create_column_option(_Option) ->
  none.

create_index(#sumo_field{name=Name, attrs=Attrs}) ->
  lists:filter(fun(T) -> is_list(T) end, lists:map(
    fun(Attr) ->
      create_index(Name, Attr)
    end,
    Attrs
  )).

create_index(Name, id) ->
  ["PRIMARY KEY(", escape(atom_to_list(Name)), ")"];

create_index(Name, unique) ->
  List = atom_to_list(Name),
  ["UNIQUE KEY ", escape(List), " (", escape(List), ")"];

create_index(Name, index) ->
  List = atom_to_list(Name),
  ["KEY ", escape(List), " (", escape(List), ")"];

create_index(_, _) ->
  none.

%% @doc Call prepare/3 first, to get a well formed statement name.
execute(Name, Args, #state{pool=Pool}) when is_atom(Name), is_list(Args) ->
  lager:debug("Executing Query: ~s -> ~p", [Name, Args]),
  {Time, Value} = timer:tc( emysql, execute, [Pool, Name, Args] ),
  lager:debug("Executed Query: ~s -> ~p (~pms)", [Name, Args, Time]),
  Value.

execute(Name, State) when is_atom(Name) ->
  execute(Name, [], State);

execute(PreQuery, #state{pool=Pool}) when is_list(PreQuery)->
  Query = iolist_to_binary(PreQuery),
  lager:debug("Executing Query: ~s", [Query]),
  {Time, Value} = timer:tc( emysql, execute, [Pool, Query] ),
  lager:debug("Executed Query: ~s (~pms)", [Query, Time]),
  Value.

prepare(DocName, PreName, Fun) when is_atom(PreName), is_function(Fun) ->
  Name = statement_name(DocName, PreName),
  case emysql_statements:fetch(Name) of
    undefined ->
      Query = iolist_to_binary(Fun()),
      lager:debug("Preparing query: ~p: ~p", [Name, Query]),
      ok = emysql:prepare(Name, Query);
    Q -> lager:debug("Using already prepared query: ~p: ~p", [Name, Q])
  end,
  Name.

%% @doc We can extend this to wrap around emysql records, so they don't end up
%% leaking details in all the repo.
evaluate_execute_result(#error_packet{status = Status, msg = Msg}, State) ->
  {error, <<Status/binary, ":", (list_to_binary(Msg))/binary>>, State}.

init(Options) ->
  Pool = list_to_atom(erlang:ref_to_list(make_ref())),
  emysql:add_pool(
    Pool, 1,
    proplists:get_value(username, Options),
    proplists:get_value(password, Options),
    proplists:get_value(host, Options, "localhost"),
    proplists:get_value(port, Options, 3306),
    proplists:get_value(database, Options),
    proplists:get_value(encoding, Options, utf8)
  ),
  {ok, #state{pool=Pool}}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Private API.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
escape(String) ->
  ["`", String, "`"].

statement_name(DocName, StatementName) ->
  list_to_atom(string:join(
    [atom_to_list(DocName), atom_to_list(StatementName), "stmt"], "_"
  )).
