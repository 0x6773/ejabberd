%%% ====================================================================
%%% ``The contents of this file are subject to the Erlang Public License,
%%% Version 1.1, (the "License"); you may not use this file except in
%%% compliance with the License. You should have received a copy of the
%%% Erlang Public License along with this software. If not, it can be
%%% retrieved via the world wide web at http://www.erlang.org/.
%%% 
%%% Software distributed under the License is distributed on an "AS IS"
%%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%%% the License for the specific language governing rights and limitations
%%% under the License.
%%% 
%%% The Initial Developer of the Original Code is ProcessOne.
%%% Portions created by ProcessOne are Copyright 2006-2010, ProcessOne
%%% All Rights Reserved.''
%%% This software is copyright 2006-2010, ProcessOne.
%%%
%%%
%%% copyright 2006-2010 ProcessOne
%%%
%%% This file contains pubsub types definition.
%%% ====================================================================

%% -------------------------------
%% Pubsub constants
-define(ERR_EXTENDED(E,C), mod_pubsub:extended_error(E,C)).

%% The actual limit can be configured with mod_pubsub's option max_items_node
-define(MAXITEMS, 10).

%% this is currently a hard limit.
%% Would be nice to have it configurable. 
-define(MAX_PAYLOAD_SIZE, 60000).

%% -------------------------------
%% Pubsub types

%%% @type host() = binary().
%%% <p><tt>host</tt> is the name of the PubSub service. For example, it can be
%%% <tt>pubsub.localhost</tt>.</p>

%%% @type node() = binary().
%%% <p>A <tt>node</tt> is the name of a Node. It can be anything and may represent
%%% some hierarchical tree depending of the node type.
%%% For example:
%%%   /home/localhost/user/node
%%%   princely_musings
%%%   http://jabber.org/protocol/tune
%%%   My-Own_Node</p>

%%% @type item() = binary().
%%% <p>An <tt>item</tt> is the name of an Item. It can be anything.
%%% For example:
%%%   38964
%%%   my-tune
%%%   FD6SBE6a27d</p>

%%% @type stanzaError() = #xmlel{}.
%%% Example: 
%%%    ```#xmlel{name = 'error'
%%%              ns = ?NS_STANZAS,
%%%              attrs = [
%%%                #xmlattr{
%%%                  name = 'code',
%%%                  ns = ?NS_STANZAS,
%%%                  value = Code
%%%                },
%%%              attrs = [
%%%                #xmlattr{
%%%                  name = 'type',
%%%                  ns = ?NS_STANZAS,
%%%                  value = Type
%%%                }
%%%              ]}'''

%%% @type pubsubIQResponse() = #xmlel{}.
%%% Example:
%%%    ```#xmlel{name = 'pubsub',
%%%              ns = ?NS_PUBSUB,
%%%              children = [
%%%                #xmlel{name = 'affiliations'
%%%                       ns = ?NS_PUBSUB
%%%                }
%%%              ]
%%%             }'''

%%% @type nodeOption() = {Option::atom(), Value::term()}.
%%% Example:
%%% ```{deliver_payloads, true}'''

%%% @type nodeType() = string().
%%% <p>The <tt>nodeType</tt> is a string containing the name of the PubSub
%%% plugin to use to manage a given node. For example, it can be
%%% <tt>"flat"</tt>, <tt>"hometree"</tt> or <tt>"blog"</tt>.</p>

%%% @type ljid() = {User::binary(), Server::binary(), Resource::binary()}.

%%% @type nodeidx() = int()

%%% @type affiliation() = none | owner | publisher | member | outcast.
%%% @type subscription() = none | pending | unconfigured | subscribed.

%%% internal pubsub index table
-record(pubsub_index, {index, last, free}).

%%% @type pubsubNode() = #pubsub_node{
%%%    id = {host(), node()},
%%%    idx = nodeidx(),
%%%    parents = [Node::pubsubNode()],
%%%    type = nodeType(),
%%%    owners = [ljid()],
%%%    options = [nodeOption()]}.
%%% <p>This is the format of the <tt>nodes</tt> table. The type of the table
%%% is: <tt>set</tt>,<tt>ram/disc</tt>.</p>
%%% <p>The <tt>parents</tt> and <tt>type</tt> fields are indexed.</p>
%%% <p><tt>nodeidx</tt> is an integer.</p>
-record(pubsub_node, {id,
		      idx,
		      parents = [],
		      type = "flat",
		      owners = [],
		      options = []
		     }).

%%% @type pubsubState() = #pubsub_state{
%%%    id = {ljid(), nodeidx()},
%%%    items = [item()],
%%%    affiliation = affiliation(),
%%%    subscriptions = [subscription()]}.
%%% <p>This is the format of the <tt>affiliations</tt> table. The type of the
%%% table is: <tt>set</tt>,<tt>ram/disc</tt>.</p>
-record(pubsub_state, {id,
		       items = [],
		       affiliation = none,
		       subscriptions = []
}).

%%% @type pubsubItem() = #pubsub_item{
%%%    id = {item(), nodeidx()},
%%%    creation = {now(), ljid()},
%%%    modification = {now(), ljid()},
%%%    payload = XMLContent::string()}.
%%% <p>This is the format of the <tt>published items</tt> table. The type of the
%%% table is: <tt>set</tt>,<tt>disc</tt>,<tt>fragmented</tt>.</p>
-record(pubsub_item, {id,
		      creation = {unknown,unknown},
		      modification = {unknown,unknown},
		      payload = []
		     }).

%% @type pubsubSubscription() = #pubsub_subscription{
%%     subid     = string(),
%%     state_key = {ljid(), nodeidx()},
%%     options   = [{atom(), term()}]
%% }.
%% <p>This is the format of the <tt>subscriptions</tt> table. The type of the
%% table is: <tt>set</tt>,<tt>ram/disc</tt>.</p>
-record(pubsub_subscription, {subid, options}).

%% @type pubsubLastItem() = #pubsub_last_item{
%%    nodeid    = nodeidx(),
%%    itemid    = item(),
%%    creation  = {now(), ljid()},
%%    payload   = XMLContent::string()}.
%% <p>This is the format of the <tt>last items</tt> table. it stores last item payload
%% for every node</p>
-record(pubsub_last_item, {nodeid, itemid, creation, payload}).
