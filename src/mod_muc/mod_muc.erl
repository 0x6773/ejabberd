%%%----------------------------------------------------------------------
%%% File    : mod_muc.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : MUC support (XEP-0045)
%%% Created : 19 Mar 2003 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2011   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

-module(mod_muc).
-author('alexey@process-one.net').

-behaviour(gen_server).
-behaviour(gen_mod).

%% API
-export([start_link/2,
	 start/2,
	 stop/1,
	 room_destroyed/4,
	 store_room/3,
	 restore_room/2,
	 forget_room/2,
	 create_room/5,
	 process_iq_disco_items/4,
	 broadcast_service_message/2,
	 register_room/3,
	 node_up/1,
         node_down/1,
	 migrate/3,
	 get_vh_rooms/1,
         is_broadcasted/1,
	 can_use_nick/3,
 	 moderate_room_history/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include("ejabberd.hrl").
-include("jlib.hrl").


-record(muc_room, {name_host, opts}).
-record(muc_online_room, {name_host, pid}).
-record(muc_registered, {us_host, nick}).

-record(state, {host,
		server_host,
		access,
		history_size,
		default_room_opts,
		room_shaper}).

-define(PROCNAME, ejabberd_mod_muc).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:start_link({local, Proc}, ?MODULE, [Host, Opts], []).

start(Host, Opts) ->
    start_supervisor(Host),
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ChildSpec =
	{Proc,
	 {?MODULE, start_link, [Host, Opts]},
	 temporary,
	 1000,
	 worker,
	 [?MODULE]},
    supervisor:start_child(ejabberd_sup, ChildSpec).

stop(Host) ->
    stop_supervisor(Host),
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:call(Proc, stop),
    supervisor:delete_child(ejabberd_sup, Proc).


moderate_room_history(RoomStr, Nick) ->
	Room = jlib:string_to_jid(RoomStr),
	Name = Room#jid.luser,
	Host = Room#jid.lserver,
	case mnesia:dirty_read(muc_online_room, {Name, Host}) of
		[] ->
			{error, not_found};
		[R] ->
		    	Pid = R#muc_online_room.pid,
			mod_muc_room:moderate_room_history(Pid, Nick)
	end.

%% This function is called by a room in three situations:
%% A) The owner of the room destroyed it
%% B) The only participant of a temporary room leaves it
%% C) mod_muc:stop was called, and each room is being terminated
%%    In this case, the mod_muc process died before the room processes
%%    So the message sending must be catched
room_destroyed(Host, Room, Pid, ServerHost) ->
    catch gen_mod:get_module_proc(ServerHost, ?PROCNAME) !
	{room_destroyed, {Room, Host}, Pid},
    ok.

%% @doc Create a room.
%% If Opts = default, the default room options are used.
%% Else use the passed options as defined in mod_muc_room.
create_room(Host, Name, From, Nick, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    RoomHost = gen_mod:get_module_opt_host(Host, ?MODULE, "conference.@HOST@"),
    Node = get_node({Name, RoomHost}),
    gen_server:call({Proc, Node}, {create, Name, From, Nick, Opts}).

store_room(Host, Name, Opts) ->
    F = fun() ->
		mnesia:write(#muc_room{name_host = {Name, Host},
				       opts = Opts})
	end,
    mnesia:transaction(F).

restore_room(Host, Name) ->
    case catch mnesia:dirty_read(muc_room, {Name, Host}) of
	[#muc_room{opts = Opts}] ->
	    Opts;
	_ ->
	    error
    end.

forget_room(Host, Name) ->
    F = fun() ->
		mnesia:delete({muc_room, {Name, Host}})
	end,
    mnesia:transaction(F).

process_iq_disco_items(Host, From, To, #iq{lang = Lang} = IQ) ->
    Rsm = jlib:rsm_decode(IQ),
    Res = IQ#iq{type = result,
		sub_el = [{xmlelement, "query",
			   [{"xmlns", ?NS_DISCO_ITEMS}],
			   iq_disco_items(Host, From, Lang, Rsm)}]},
    ejabberd_router:route(To,
			  From,
			  jlib:iq_to_xml(Res)).

can_use_nick(_Host, _JID, "") ->
    false;
can_use_nick(Host, JID, Nick) ->
    {LUser, LServer, _} = jlib:jid_tolower(JID),
    LUS = {LUser, LServer},
    case catch mnesia:dirty_select(
		 muc_registered,
		 [{#muc_registered{us_host = '$1',
				   nick = Nick,
				   _ = '_'},
		   [{'==', {element, 2, '$1'}, Host}],
		   ['$_']}]) of
	{'EXIT', _Reason} ->
	    true;
	[] ->
	    true;
	[#muc_registered{us_host = {U, _Host}}] ->
	    U == LUS
    end.

migrate(_Node, _UpOrDown, After) ->
    Rs = mnesia:dirty_select(
	   muc_online_room,
	   [{#muc_online_room{name_host = '$1', pid = '$2', _ = '_'},
	     [],
	     ['$$']}]),
    lists:foreach(
      fun([NameHost, Pid]) ->
	      case get_node(NameHost) of
		  Node when Node /= node() ->
		      mod_muc_room:migrate(Pid, Node, random:uniform(After));
		  _ ->
		      ok
	      end
      end, Rs).

node_up(_Node) ->
    copy_rooms(mnesia:dirty_first(muc_online_room)).

node_down(Node) when Node == node() ->
    copy_rooms(mnesia:dirty_first(muc_online_room));
node_down(_) ->
    ok.

copy_rooms('$end_of_table') ->
    ok;
copy_rooms(Key) ->
    case mnesia:dirty_read(muc_online_room, Key) of
        [#muc_online_room{name_host = NameHost} = Room] ->
            case get_node_new(NameHost) of
                Node when node() /= Node ->
                    rpc:cast(Node, mnesia, dirty_write, [Room]);
                _ ->
                    ok
            end;
        _ ->
            ok
    end,
    copy_rooms(mnesia:dirty_next(muc_online_room, Key)).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([Host, Opts]) ->
    update_muc_online_table(),
    mnesia:create_table(muc_room,
			[{disc_copies, [node()]},
			 {attributes, record_info(fields, muc_room)}]),
    mnesia:create_table(muc_registered,
			[{disc_copies, [node()]},
			 {attributes, record_info(fields, muc_registered)}]),
    mnesia:create_table(muc_online_room,
			[{ram_copies, [node()]},
			 {local_content, true},
			 {attributes, record_info(fields, muc_online_room)}]),
    mnesia:add_table_copy(muc_online_room, node(), ram_copies),
    catch ets:new(muc_online_users, [bag, named_table, public, {keypos, 2}]),
    MyHost = gen_mod:get_opt_host(Host, Opts, "conference.@HOST@"),
    update_tables(MyHost),
    mnesia:add_table_index(muc_registered, nick),
    Access = gen_mod:get_opt(access, Opts, all),
    AccessCreate = gen_mod:get_opt(access_create, Opts, all),
    AccessAdmin = gen_mod:get_opt(access_admin, Opts, none),
    AccessPersistent = gen_mod:get_opt(access_persistent, Opts, all),
    HistorySize = gen_mod:get_opt(history_size, Opts, 20),
    DefRoomOpts = gen_mod:get_opt(default_room_options, Opts, []),
    RoomShaper = gen_mod:get_opt(room_shaper, Opts, none),
    ejabberd_router:register_route(MyHost),
    ejabberd_hooks:add(node_up, ?MODULE, node_up, 100),
    ejabberd_hooks:add(node_down, ?MODULE, node_down, 100),
    ejabberd_hooks:add(node_hash_update, ?MODULE, migrate, 100),
    load_permanent_rooms(MyHost, Host,
			 {Access, AccessCreate, AccessAdmin, AccessPersistent},
			 HistorySize,
			 RoomShaper),
    {ok, #state{host = MyHost,
		server_host = Host,
		access = {Access, AccessCreate, AccessAdmin, AccessPersistent},
		default_room_opts = DefRoomOpts,
		history_size = HistorySize,
		room_shaper = RoomShaper}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(stop, _From, State) ->
    {stop, normal, ok, State};

handle_call({create, Room, From, Nick, Opts},
	    _From,
	    #state{host = Host,
		   server_host = ServerHost,
		   access = Access,
		   default_room_opts = DefOpts,
		   history_size = HistorySize,
		   room_shaper = RoomShaper} = State) ->
    ?DEBUG("MUC: create new room '~s'~n", [Room]),
    NewOpts = case Opts of
		  default -> DefOpts;
		  _ -> Opts
	      end,
    {ok, Pid} = mod_muc_room:start(
		  Host, ServerHost, Access,
		  Room, HistorySize,
		  RoomShaper, From,
		  Nick, NewOpts),
    register_room(Host, Room, Pid),
    {reply, ok, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({route, From, To, Packet},
	    #state{host = Host,
		   server_host = ServerHost,
		   access = Access,
 		   default_room_opts = DefRoomOpts,
		   history_size = HistorySize,
		   room_shaper = RoomShaper} = State) ->
    {U, S, _} = jlib:jid_tolower(To),
    case get_node({U, S}) of
	Node when Node == node() ->
	    case catch do_route(Host, ServerHost, Access, HistorySize,
				RoomShaper, From, To, Packet, DefRoomOpts) of
		{'EXIT', Reason} ->
		    ?ERROR_MSG("~p", [Reason]);
		_ ->
		    ok
	    end;
	Node ->
	    Proc = gen_mod:get_module_proc(ServerHost, ?PROCNAME),
	    {Proc, Node} ! {route, From, To, Packet}
    end,
    {noreply, State};
handle_info({room_destroyed, RoomHost, Pid}, State) ->
    F = fun() ->
		mnesia:delete_object(#muc_online_room{name_host = RoomHost,
						      pid = Pid})
	end,
    mnesia:async_dirty(F),
    case get_node_new(RoomHost) of
	Node when Node /= node() ->
	    rpc:cast(Node, mnesia, dirty_delete_object,
		     [#muc_online_room{name_host = RoomHost,
				       pid = Pid}]);
	_ ->
	    ok
    end,
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, State) ->
    ejabberd_hooks:delete(node_up, ?MODULE, node_up, 100),
    ejabberd_hooks:delete(node_down, ?MODULE, node_down, 100),
    ejabberd_hooks:delete(node_hash_update, ?MODULE, migrate, 100),
    ejabberd_router:unregister_route(State#state.host),
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
start_supervisor(Host) ->
    Proc = gen_mod:get_module_proc(Host, ejabberd_mod_muc_sup),
    ChildSpec =
	{Proc,
	 {ejabberd_tmp_sup, start_link,
	  [Proc, mod_muc_room]},
	 permanent,
	 infinity,
	 supervisor,
	 [ejabberd_tmp_sup]},
    supervisor:start_child(ejabberd_sup, ChildSpec).

stop_supervisor(Host) ->
    Proc = gen_mod:get_module_proc(Host, ejabberd_mod_muc_sup),
    supervisor:terminate_child(ejabberd_sup, Proc),
    supervisor:delete_child(ejabberd_sup, Proc).

do_route(Host, ServerHost, Access, HistorySize, RoomShaper,
	 From, To, Packet, DefRoomOpts) ->
    {AccessRoute, _AccessCreate, _AccessAdmin, _AccessPersistent} = Access,
    case acl:match_rule(ServerHost, AccessRoute, From) of
	allow ->
	    do_route1(Host, ServerHost, Access, HistorySize, RoomShaper,
		      From, To, Packet, DefRoomOpts);
	_ ->
	    {xmlelement, _Name, Attrs, _Els} = Packet,
	    Lang = xml:get_attr_s("xml:lang", Attrs),
	    ErrText = "Access denied by service policy",
	    Err = jlib:make_error_reply(Packet,
					?ERRT_FORBIDDEN(Lang, ErrText)),
	    ejabberd_router:route_error(To, From, Err, Packet)
    end.


do_route1(Host, ServerHost, Access, HistorySize, RoomShaper,
	  From, To, Packet, DefRoomOpts) ->
    {_AccessRoute, AccessCreate, AccessAdmin, _AccessPersistent} = Access,
    {Room, _, Nick} = jlib:jid_tolower(To),
    {xmlelement, Name, Attrs, _Els} = Packet,
    case Room of
	"" ->
	    case Nick of
		"" ->
		    case Name of
			"iq" ->
			    case jlib:iq_query_info(Packet) of
				#iq{type = get, xmlns = ?NS_DISCO_INFO = XMLNS,
 				    sub_el = _SubEl, lang = Lang} = IQ ->
				    Info = ejabberd_hooks:run_fold(
					     disco_info, ServerHost, [],
					     [ServerHost, ?MODULE, "", ""]),
				    Res = IQ#iq{type = result,
						sub_el = [{xmlelement, "query",
							   [{"xmlns", XMLNS}],
							   iq_disco_info(Lang)
							   ++Info}]},
				    ejabberd_router:route(To,
							  From,
							  jlib:iq_to_xml(Res));
				#iq{type = get,
				    xmlns = ?NS_DISCO_ITEMS} = IQ ->
				    spawn(?MODULE,
					  process_iq_disco_items,
					  [Host, From, To, IQ]);
				#iq{type = get,
				    xmlns = ?NS_REGISTER = XMLNS,
				    lang = Lang,
				    sub_el = _SubEl} = IQ ->
				    Res = IQ#iq{type = result,
						sub_el =
						[{xmlelement, "query",
						  [{"xmlns", XMLNS}],
						  iq_get_register_info(
						    Host, From, Lang)}]},
				    ejabberd_router:route(To,
							  From,
							  jlib:iq_to_xml(Res));
				#iq{type = set,
				    xmlns = ?NS_REGISTER = XMLNS,
				    lang = Lang,
				    sub_el = SubEl} = IQ ->
				    case process_iq_register_set(Host, From, SubEl, Lang) of
					{result, IQRes} ->
					    Res = IQ#iq{type = result,
							sub_el =
							[{xmlelement, "query",
							  [{"xmlns", XMLNS}],
							  IQRes}]},
					    ejabberd_router:route(
					      To, From, jlib:iq_to_xml(Res));
					{error, Error} ->
					    Err = jlib:make_error_reply(
						    Packet, Error),
					    ejabberd_router:route(
					      To, From, Err)
				    end;
				#iq{type = get,
				    xmlns = ?NS_VCARD = XMLNS,
				    lang = Lang,
				    sub_el = _SubEl} = IQ ->
				    Res = IQ#iq{type = result,
						sub_el =
						[{xmlelement, "vCard",
						  [{"xmlns", XMLNS}],
						  iq_get_vcard(Lang)}]},
				    ejabberd_router:route(To,
							  From,
							  jlib:iq_to_xml(Res));
				#iq{type = get,
				   xmlns = ?NS_MUC_UNIQUE
				   } = IQ ->
				   Res = IQ#iq{type = result,
						sub_el =
						[{xmlelement, "unique",
						   [{"xmlns", ?NS_MUC_UNIQUE}],
						   [iq_get_unique(From)]}]},
				   ejabberd_router:route(To,
				   			 From,
							 jlib:iq_to_xml(Res));
				#iq{} ->
				    Err = jlib:make_error_reply(
					    Packet,
					    ?ERR_FEATURE_NOT_IMPLEMENTED),
				    ejabberd_router:route(To, From, Err);
				_ ->
				    ok
			    end;
			"message" ->
			    case xml:get_attr_s("type", Attrs) of
				"error" ->
				    ok;
				_ ->
				    case acl:match_rule(ServerHost, AccessAdmin, From) of
					allow ->
					    Msg = xml:get_path_s(
						    Packet,
						    [{elem, "body"}, cdata]),
					    broadcast_service_message(Host, Msg);
					_ ->
					    Lang = xml:get_attr_s("xml:lang", Attrs),
					    ErrText = "Only service administrators "
						      "are allowed to send service messages",
					    Err = jlib:make_error_reply(
						    Packet,
						    ?ERRT_FORBIDDEN(Lang, ErrText)),
					    ejabberd_router:route(
					      To, From, Err)
				    end
			    end;
			"presence" ->
			    ok
		    end;
		_ ->
		    case xml:get_attr_s("type", Attrs) of
			"error" ->
			    ok;
			"result" ->
			    ok;
			_ ->
			    Err = jlib:make_error_reply(
				    Packet, ?ERR_ITEM_NOT_FOUND),
			    ejabberd_router:route(To, From, Err)
		    end
	    end;
	_ ->
	    case mnesia:dirty_read(muc_online_room, {Room, Host}) of
		[] ->
		    Type = xml:get_attr_s("type", Attrs),
		    case {Name, Type} of
			{"presence", ""} ->
			    case check_user_can_create_room(ServerHost,
							    AccessCreate, From,
							    Room) of
				true ->
				    case start_new_room(
					   Host, ServerHost, Access,
					   Room, HistorySize,
					   RoomShaper, From,
					   Nick, DefRoomOpts) of
					{ok, Pid} ->
					    mod_muc_room:route(Pid, From, Nick, Packet),
					    register_room(Host, Room, Pid),
					    ok;
					_Err ->
					    Err = jlib:make_error_reply(
						    Packet, ?ERR_INTERNAL_SERVER_ERROR),
					    ejabberd_router:route(To, From, Err)
				    end;
				false ->
				    Lang = xml:get_attr_s("xml:lang", Attrs),
				    ErrText = "Room creation is denied by service policy",
				    Err = jlib:make_error_reply(
					    Packet, ?ERRT_FORBIDDEN(Lang, ErrText)),
				    ejabberd_router:route(To, From, Err)
			    end;
			_ ->
			    Lang = xml:get_attr_s("xml:lang", Attrs),
			    ErrText = "Conference room does not exist",
			    Err = jlib:make_error_reply(
				    Packet, ?ERRT_ITEM_NOT_FOUND(Lang, ErrText)),
			    ejabberd_router:route(To, From, Err)
		    end;
		[R] ->
		    Pid = R#muc_online_room.pid,
		    ?DEBUG("MUC: send to process ~p~n", [Pid]),
		    mod_muc_room:route(Pid, From, Nick, Packet),
		    ok
	    end
    end.

check_user_can_create_room(ServerHost, AccessCreate, From, RoomID) ->
    case acl:match_rule(ServerHost, AccessCreate, From) of
	allow ->
	    (length(RoomID) =< gen_mod:get_module_opt(ServerHost, mod_muc,
						      max_room_id, infinite));
	_ ->
	    false
    end.


load_permanent_rooms(Host, ServerHost, Access, HistorySize, RoomShaper) ->
    case catch mnesia:dirty_select(
		 muc_room, [{#muc_room{name_host = {'_', Host}, _ = '_'},
			     [],
			     ['$_']}]) of
	{'EXIT', Reason} ->
	    ?ERROR_MSG("~p", [Reason]),
	    ok;
	Rs ->
	    lists:foreach(
	      fun(R) ->
		      {Room, Host} = R#muc_room.name_host,
		      case get_node({Room, Host}) of
			  Node when Node == node() ->
			      case mnesia:dirty_read(muc_online_room, {Room, Host}) of
				  [] ->
                                      case get_room_state_if_broadcasted(
                                             {Room, Host}) of
                                          {ok, RoomState} ->
                                              mod_muc_room:start(
                                                normal_state, RoomState);
                                          error ->
                                              {ok, Pid} = mod_muc_room:start(
                                                            Host,
                                                            ServerHost,
                                                            Access,
                                                            Room,
                                                            HistorySize,
                                                            RoomShaper,
                                                            R#muc_room.opts),
                                              register_room(Host, Room, Pid)
                                      end;
				  _ ->
				      ok
			      end;
			  _ ->
			      ok
		      end
	      end, Rs)
    end.

start_new_room(Host, ServerHost, Access, Room,
	       HistorySize, RoomShaper, From,
	       Nick, DefRoomOpts) ->
    case get_room_state_if_broadcasted({Room, Host}) of
        {ok, RoomState} ->
            ?DEBUG("MUC: restore room '~s' from other node~n", [Room]),
            mod_muc_room:start(normal_state, RoomState);
        error ->
            case mnesia:dirty_read(muc_room, {Room, Host}) of
                [] ->
                    ?DEBUG("MUC: open new room '~s'~n", [Room]),
                    mod_muc_room:start(Host, ServerHost, Access,
                                       Room, HistorySize,
                                       RoomShaper, From,
                                       Nick, DefRoomOpts);
                [#muc_room{opts = Opts}|_] ->
                    ?DEBUG("MUC: restore room '~s'~n", [Room]),
                    mod_muc_room:start(Host, ServerHost, Access,
                                       Room, HistorySize,
                                       RoomShaper, Opts)
            end
    end.

register_room(Host, Room, Pid) ->
    F = fun() ->
    		mnesia:write(#muc_online_room{name_host = {Room, Host},
    					      pid = Pid})
    	end,
    mnesia:async_dirty(F),
    case get_node_new({Room, Host}) of
	Node when Node /= node() ->
	    %% New node has just been added. But we may miss MUC records
            %% copy procedure, so we copy the MUC record manually just
            %% to make sure
	    rpc:cast(Node, mnesia, dirty_write,
		     [#muc_online_room{name_host = {Room, Host},
				       pid = Pid}]),
	    case get_node({Room, Host}) of
                Node when node() /= Node ->
                    %% Migration to new node has completed, and seems like
                    %% we missed it, so we migrate the MUC room pid manually.
                    %% It is not a problem if we have already got migration
                    %% notification: dups are just ignored by the MUC room pid.
                    mod_muc_room:migrate(Pid, Node, 0);
                _ ->
                    ok
            end;
	_ ->
	    ok
    end.

iq_disco_info(Lang) ->
    [{xmlelement, "identity",
      [{"category", "conference"},
       {"type", "text"},
       {"name", translate:translate(Lang, "Chatrooms")}], []},
     {xmlelement, "feature", [{"var", ?NS_DISCO_INFO}], []},
     {xmlelement, "feature", [{"var", ?NS_DISCO_ITEMS}], []},
     {xmlelement, "feature", [{"var", ?NS_MUC}], []},
     {xmlelement, "feature", [{"var", ?NS_MUC_UNIQUE}], []},
     {xmlelement, "feature", [{"var", ?NS_REGISTER}], []},
     {xmlelement, "feature", [{"var", ?NS_RSM}], []},
     {xmlelement, "feature", [{"var", ?NS_VCARD}], []}].


iq_disco_items(Host, From, Lang, none) ->
    lists:zf(fun(#muc_online_room{name_host = {Name, _Host}, pid = Pid}) ->
		     case catch gen_fsm:sync_send_all_state_event(
				  Pid, {get_disco_item, From, Lang}, 100) of
			 {item, Desc} ->
			     flush(),
			     {true,
			      {xmlelement, "item",
			       [{"jid", jlib:jid_to_string({Name, Host, ""})},
				{"name", Desc}], []}};
			 _ ->
			     false
		     end
	     end, get_vh_rooms_all_nodes(Host));

iq_disco_items(Host, From, Lang, Rsm) ->
    {Rooms, RsmO} = get_vh_rooms(Host, Rsm),
    RsmOut = jlib:rsm_encode(RsmO),
    lists:zf(fun(#muc_online_room{name_host = {Name, _Host}, pid = Pid}) ->
		     case catch gen_fsm:sync_send_all_state_event(
				  Pid, {get_disco_item, From, Lang}, 100) of
			 {item, Desc} ->
			     flush(),
			     {true,
			      {xmlelement, "item",
			       [{"jid", jlib:jid_to_string({Name, Host, ""})},
				{"name", Desc}], []}};
			 _ ->
			     false
		     end
	     end, Rooms) ++ RsmOut.

get_vh_rooms(Host, #rsm_in{max=M, direction=Direction, id=I, index=Index})->
    AllRooms = get_vh_rooms_all_nodes(Host),
    Count = erlang:length(AllRooms),
    L = get_vh_rooms_direction(Direction, I, Index, AllRooms),
    L2 = if
	     Index == undefined andalso Direction == before ->
		 lists:reverse(lists:sublist(lists:reverse(L), 1, M));
	     Index == undefined ->
		 lists:sublist(L, 1, M);
	     Index > Count  orelse Index < 0 ->
		 [];
	     true ->
		 lists:sublist(L, Index+1, M)
	 end,
    if
	L2 == [] ->
	    {L2, #rsm_out{count=Count}};
	true ->
	    H = hd(L2),
	    NewIndex = get_room_pos(H, AllRooms),
	    T=lists:last(L2),
	    {F, _}=H#muc_online_room.name_host,
	    {Last, _}=T#muc_online_room.name_host,
	    {L2, #rsm_out{first=F, last=Last, count=Count, index=NewIndex}}
    end.

get_vh_rooms_direction(_Direction, _I, Index, AllRooms) when Index =/= undefined ->
		AllRooms;
get_vh_rooms_direction(aft, I, _Index, AllRooms) ->
    {_Before, After} =
	lists:splitwith(
	  fun(#muc_online_room{name_host = {Na, _}}) ->
		  Na < I end, AllRooms),
    case After of
	[] -> [];
	[#muc_online_room{name_host = {I, _Host}} | AfterTail] -> AfterTail;
	_ -> After
    end;
get_vh_rooms_direction(before, I, _Index, AllRooms) when I =/= []->
    {Before, _} =
	lists:splitwith(
	  fun(#muc_online_room{name_host = {Na, _}}) ->
		  Na < I end, AllRooms),
    Before;
get_vh_rooms_direction(_Direction, _I, _Index, AllRooms) ->
    AllRooms.

%% @doc Return the position of desired room in the list of rooms.
%% The room must exist in the list. The count starts in 0.
%% @spec (Desired::muc_online_room(), Rooms::[muc_online_room()]) -> integer()
get_room_pos(Desired, Rooms) ->
    get_room_pos(Desired, Rooms, 0).
get_room_pos(Desired, [HeadRoom | _], HeadPosition)
  when (Desired#muc_online_room.name_host ==
	HeadRoom#muc_online_room.name_host) ->
    HeadPosition;
get_room_pos(Desired, [_ | Rooms], HeadPosition) ->
    get_room_pos(Desired, Rooms, HeadPosition + 1).

flush() ->
    receive
	_ ->
	    flush()
    after 0 ->
	    ok
    end.

-define(XFIELD(Type, Label, Var, Val),
	{xmlelement, "field", [{"type", Type},
			       {"label", translate:translate(Lang, Label)},
			       {"var", Var}],
	 [{xmlelement, "value", [], [{xmlcdata, Val}]}]}).

%% @doc Get a pseudo unique Room Name. The Room Name is generated as a hash of 
%%      the requester JID, the local time and a random salt.
%%
%%      "pseudo" because we don't verify that there is not a room
%%       with the returned Name already created, nor mark the generated Name 
%%       as "already used".  But in practice, it is unique enough. See
%%       http://xmpp.org/extensions/xep-0045.html#createroom-unique
iq_get_unique(From) ->
	{xmlcdata, sha:sha(term_to_binary([From, now(), randoms:get_string()]))}.

iq_get_register_info(Host, From, Lang) ->
    {LUser, LServer, _} = jlib:jid_tolower(From),
    LUS = {LUser, LServer},
    {Nick, Registered} =
	case catch mnesia:dirty_read(muc_registered, {LUS, Host}) of
	    {'EXIT', _Reason} ->
		{"", []};
	    [] ->
		{"", []};
	    [#muc_registered{nick = N}] ->
		{N, [{xmlelement, "registered", [], []}]}
	end,
    Registered ++
	[{xmlelement, "instructions", [],
	  [{xmlcdata,
	    translate:translate(
	      Lang, "You need a client that supports x:data to register the nickname")}]},
	 {xmlelement, "x",
	  [{"xmlns", ?NS_XDATA}],
	  [{xmlelement, "title", [],
	    [{xmlcdata,
	      translate:translate(
		Lang, "Nickname Registration at ") ++ Host}]},
	   {xmlelement, "instructions", [],
	    [{xmlcdata,
	      translate:translate(
		Lang, "Enter nickname you want to register")}]},
	   ?XFIELD("text-single", "Nickname", "nick", Nick)]}].

iq_set_register_info(Host, From, Nick, Lang) ->
    {LUser, LServer, _} = jlib:jid_tolower(From),
    LUS = {LUser, LServer},
    F = fun() ->
		case Nick of
		    "" ->
			mnesia:delete({muc_registered, {LUS, Host}}),
			ok;
		    _ ->
			Allow =
			    case mnesia:select(
				   muc_registered,
				   [{#muc_registered{us_host = '$1',
						     nick = Nick,
						     _ = '_'},
				     [{'==', {element, 2, '$1'}, Host}],
				     ['$_']}]) of
				[] ->
				    true;
				[#muc_registered{us_host = {U, _Host}}] ->
				    U == LUS
			    end,
			if
			    Allow ->
				mnesia:write(
				  #muc_registered{us_host = {LUS, Host},
						  nick = Nick}),
				ok;
			    true ->
				false
			end
		end
	end,
    case mnesia:transaction(F) of
	{atomic, ok} ->
	    {result, []};
	{atomic, false} ->
	    ErrText = "That nickname is registered by another person",
	    {error, ?ERRT_CONFLICT(Lang, ErrText)};
	_ ->
	    {error, ?ERR_INTERNAL_SERVER_ERROR}
    end.

process_iq_register_set(Host, From, SubEl, Lang) ->
    {xmlelement, _Name, _Attrs, Els} = SubEl,
    case xml:get_subtag(SubEl, "remove") of
	false ->
	    case xml:remove_cdata(Els) of
		[{xmlelement, "x", _Attrs1, _Els1} = XEl] ->
		    case {xml:get_tag_attr_s("xmlns", XEl),
			  xml:get_tag_attr_s("type", XEl)} of
			{?NS_XDATA, "cancel"} ->
			    {result, []};
			{?NS_XDATA, "submit"} ->
			    XData = jlib:parse_xdata_submit(XEl),
			    case XData of
				invalid ->
				    {error, ?ERR_BAD_REQUEST};
				_ ->
				    case lists:keysearch("nick", 1, XData) of
					{value, {_, [Nick]}} when Nick /= "" ->
					    iq_set_register_info(Host, From, Nick, Lang);
					_ ->
					    ErrText = "You must fill in field \"Nickname\" in the form",
					    {error, ?ERRT_NOT_ACCEPTABLE(Lang, ErrText)}
				    end
			    end;
			_ ->
			    {error, ?ERR_BAD_REQUEST}
		    end;
		_ ->
		    {error, ?ERR_BAD_REQUEST}
	    end;
	_ ->
	    iq_set_register_info(Host, From, "", Lang)
    end.

iq_get_vcard(Lang) ->
    [{xmlelement, "FN", [],
      [{xmlcdata, "ejabberd/mod_muc"}]},
     {xmlelement, "URL", [],
      [{xmlcdata, ?EJABBERD_URI}]},
     {xmlelement, "DESC", [],
      [{xmlcdata, translate:translate(Lang, "ejabberd MUC module") ++
	  "\nCopyright (c) 2003-2011 ProcessOne"}]}].


broadcast_service_message(Host, Msg) ->
    lists:foreach(
      fun(#muc_online_room{pid = Pid}) ->
	      gen_fsm:send_all_state_event(
		Pid, {service_message, Msg})
      end, get_vh_rooms_all_nodes(Host)).

get_vh_rooms_all_nodes(Host) ->
    Rooms = lists:foldl(
	      fun(Node, Acc) when Node == node() ->
		      get_vh_rooms(Host) ++ Acc;
		 (Node, Acc) ->
		      case catch rpc:call(Node, ?MODULE, get_vh_rooms,
					  [Host], 5000) of
			  Res when is_list(Res) ->
			      Res ++ Acc;
			  _ ->
			      Acc
		      end
	      end, [], get_nodes(Host)),
    lists:ukeysort(#muc_online_room.name_host, Rooms).

get_vh_rooms(Host) ->
    mnesia:dirty_select(muc_online_room,
			[{#muc_online_room{name_host = '$1', _ = '_'},
			  [{'==', {element, 2, '$1'}, Host}],
			  ['$_']}]).

update_tables(Host) ->
    update_muc_room_table(Host),
    update_muc_registered_table(Host).

update_muc_online_table() ->
    case catch mnesia:table_info(muc_online_room, local_content) of
	false ->
	    mnesia:delete_table(muc_online_room);
	_ ->
	    ok
    end.

update_muc_room_table(Host) ->
    Fields = record_info(fields, muc_room),
    case mnesia:table_info(muc_room, attributes) of
	Fields ->
	    ok;
	[name, opts] ->
	    ?INFO_MSG("Converting muc_room table from "
		      "{name, opts} format", []),
	    {atomic, ok} = mnesia:create_table(
			     mod_muc_tmp_table,
			     [{disc_only_copies, [node()]},
			      {type, bag},
			      {local_content, true},
			      {record_name, muc_room},
			      {attributes, record_info(fields, muc_room)}]),
	    mnesia:transform_table(muc_room, ignore, Fields),
	    F1 = fun() ->
			 mnesia:write_lock_table(mod_muc_tmp_table),
			 mnesia:foldl(
			   fun(#muc_room{name_host = Name} = R, _) ->
				   mnesia:dirty_write(
				     mod_muc_tmp_table,
				     R#muc_room{name_host = {Name, Host}})
			   end, ok, muc_room)
		 end,
	    mnesia:transaction(F1),
	    mnesia:clear_table(muc_room),
	    F2 = fun() ->
			 mnesia:write_lock_table(muc_room),
			 mnesia:foldl(
			   fun(R, _) ->
				   mnesia:dirty_write(R)
			   end, ok, mod_muc_tmp_table)
		 end,
	    mnesia:transaction(F2),
	    mnesia:delete_table(mod_muc_tmp_table);
	_ ->
	    ?INFO_MSG("Recreating muc_room table", []),
	    mnesia:transform_table(muc_room, ignore, Fields)
    end.


update_muc_registered_table(Host) ->
    Fields = record_info(fields, muc_registered),
    case mnesia:table_info(muc_registered, attributes) of
	Fields ->
	    ok;
	[user, nick] ->
	    ?INFO_MSG("Converting muc_registered table from "
		      "{user, nick} format", []),
	    {atomic, ok} = mnesia:create_table(
			     mod_muc_tmp_table,
			     [{disc_only_copies, [node()]},
			      {type, bag},
			      {local_content, true},
			      {record_name, muc_registered},
			      {attributes, record_info(fields, muc_registered)}]),
	    mnesia:del_table_index(muc_registered, nick),
	    mnesia:transform_table(muc_registered, ignore, Fields),
	    F1 = fun() ->
			 mnesia:write_lock_table(mod_muc_tmp_table),
			 mnesia:foldl(
			   fun(#muc_registered{us_host = US} = R, _) ->
				   mnesia:dirty_write(
				     mod_muc_tmp_table,
				     R#muc_registered{us_host = {US, Host}})
			   end, ok, muc_registered)
		 end,
	    mnesia:transaction(F1),
	    mnesia:clear_table(muc_registered),
	    F2 = fun() ->
			 mnesia:write_lock_table(muc_registered),
			 mnesia:foldl(
			   fun(R, _) ->
				   mnesia:dirty_write(R)
			   end, ok, mod_muc_tmp_table)
		 end,
	    mnesia:transaction(F2),
	    mnesia:delete_table(mod_muc_tmp_table);
	_ ->
	    ?INFO_MSG("Recreating muc_registered table", []),
	    mnesia:transform_table(muc_registered, ignore, Fields)
    end.

is_broadcasted(RoomHost) ->
    case ejabberd_config:get_local_option({domain_balancing, RoomHost}) of
        broadcast ->
            true;
        _ ->
            false
    end.

get_node({_, RoomHost} = Key) ->
    case is_broadcasted(RoomHost) of
        true ->
            node();
        false ->
            ejabberd_cluster:get_node(Key)
    end;
get_node(RoomHost) ->
    get_node({"", RoomHost}).

get_node_new({_, RoomHost} = Key) ->
    case is_broadcasted(RoomHost) of
        true ->
            node();
        false ->
            ejabberd_cluster:get_node_new(Key)
    end;
get_node_new(RoomHost) ->
    get_node_new({"", RoomHost}).

get_nodes(RoomHost) ->
    case is_broadcasted(RoomHost) of
        true ->
            [node()];
        false ->
            ejabberd_cluster:get_nodes()
    end.

get_room_state_if_broadcasted({Room, Host}) ->
    case is_broadcasted(Host) of
        true ->
            lists:foldl(
              fun(_, {ok, StateData}) ->
                      {ok, StateData};
                 (Node, _) when Node /= node() ->
                      case catch rpc:call(
                                   Node, mnesia, dirty_read,
                                   [muc_online_room, {Room, Host}], 5000) of
                          [#muc_online_room{pid = Pid}] ->
                              case catch gen_fsm:sync_send_all_state_event(
                                           Pid, get_state, 5000) of
                                  {ok, StateData} ->
                                      {ok, StateData};
                                  _ ->
                                      error
                              end;
                          _ ->
                              error
                      end;
                 (_, Acc) ->
                      Acc
              end, error, ejabberd_cluster:get_nodes());
        false ->
            error
    end.
