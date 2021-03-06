-module(twerl).

-behaviour(gen_server).

-compile(export_all).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(BASE, "http://api.twitter.com/1").
-define(SEARCH, "http://search.twitter.com/search.json").
-define(XAUTH, "https://api.twitter.com/oauth/access_token").
-define(HTTP_OPTIONS, [{timeout, 120000}]).
-define(TIMEOUT, 180000).
-define(USERAGENT, "PavoMe").

-record(state, {}).

%% ====================================================================
%% External functions
%% ====================================================================

start_link() -> 
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

direct_messages(Auth, Args) -> gen_server:call(?MODULE, {direct_messages, Auth, Args}, ?TIMEOUT).
direct_messages_sent(Auth, Args) -> gen_server:call(?MODULE, {direct_messages_sent, Auth, Args}, ?TIMEOUT).
direct_message_destroy(Auth, Args) -> gen_server:call(?MODULE, {direct_messages_destroy, Auth, Args}, ?TIMEOUT).
direct_message_new(Auth, Args) -> gen_server:call(?MODULE, {direct_messages_new, Auth, Args}, ?TIMEOUT).
friendship_create(Auth, Args) -> gen_server:call(?MODULE, {friendships_create, Auth, Args}, ?TIMEOUT).
friendship_destroy(Auth, Args) -> gen_server:call(?MODULE, {friendships_destroy, Auth, Args}, ?TIMEOUT).
statuses_home_timeline(Auth, Args) -> gen_server:call(?MODULE, {statuses_home_timeline, Auth, Args}, ?TIMEOUT).
statuses_mentions(Auth, Args) -> gen_server:call(?MODULE, {statuses_mentions, Auth, Args}, ?TIMEOUT).
statuses_show(Auth, Args) -> gen_server:call(?MODULE, {statuses_show, Auth, Args}, ?TIMEOUT).
status_update(Auth, Args) -> gen_server:call(?MODULE, {statuses_update, Auth, Args}, ?TIMEOUT).
status_destroy(Auth, Args) -> gen_server:call(?MODULE, {statuses_destroy, Auth, Args}, ?TIMEOUT).
status_retweet(Auth, Args) -> gen_server:call(?MODULE, {statuses_retweet, Auth, Args}, ?TIMEOUT).
statuses_user_timeline(Auth, Args) -> gen_server:call(?MODULE, {statuses_user_timeline, Auth, Args}, ?TIMEOUT).
user_show(Auth, Args) -> gen_server:call(?MODULE, {users_show, Auth, Args}, ?TIMEOUT).
favorites(Auth, Args) -> gen_server:call(?MODULE, {favorites, Auth, Args}, ?TIMEOUT).
favorites_create(Auth, Args) -> gen_server:call(?MODULE, {favorites_create, Auth, Args}, ?TIMEOUT).
favorites_destroy(Auth, Args) -> gen_server:call(?MODULE, {favorites_destroy, Auth, Args}, ?TIMEOUT).
search(Args) -> gen_server:call(?MODULE, {search, Args}, ?TIMEOUT).
xauth(Consumer, Username, Password) -> gen_server:call(?MODULE, {xauth, Consumer, Username, Password}, ?TIMEOUT).

%% ====================================================================
%% Server functions
%% ====================================================================

%% --------------------------------------------------------------------
%% Function: init/1
%% Description: Initiates the server
%% Returns: {ok, State}          |
%%          {ok, State, Timeout} |
%%          ignore               |
%%          {stop, Reason}
%% --------------------------------------------------------------------
init([]) ->
    ets:new(twerl, [named_table]),
    {ok, #state{}}.

%% --------------------------------------------------------------------
%% Function: handle_call/3
%% Description: Handling call messages
%% Returns: {reply, Reply, State}          |
%%          {reply, Reply, State, Timeout} |
%%          {noreply, State}               |
%%          {noreply, State, Timeout}      |
%%          {stop, Reason, Reply, State}   | (terminate/2 is called)
%%          {stop, Reason, State}            (terminate/2 is called)
%% --------------------------------------------------------------------
handle_call({xauth, Consumer, Username, Password}, From, #state{} = State) ->
    Args = [{"x_auth_username", Username}, {"x_auth_password", Password}, {"x_auth_mode", "client_auth"}],
    SignedParams = oauth:signed_params("POST", ?XAUTH, Args, Consumer, "", ""),
    Post = oauth_uri:params_to_string(SignedParams),
    {ok, RequestId} = http:request(post, {?XAUTH, [], "application/x-www-form-urlencoded", Post}, [{timeout, 15000}], [{sync, false}]),
	ets:insert(twerl, {RequestId, xauth, From}),
    {noreply, State};

handle_call({search, Args}, From, #state{} = State) ->
    URL = ?SEARCH ++ "?" ++ oauth_uri:params_to_string([{to_list(K), to_list(V)} || {K, V} <- Args]),
	{ok, RequestId} = http:request(get, {URL, [{"user-agent", ?USERAGENT}]}, ?HTTP_OPTIONS, [{sync, false}]),
	ets:insert(twerl, {RequestId, search, From}),
    {noreply, State};

handle_call({Request, Auth, Args}, From, #state{} = State) ->
	{Method, URL, NormalArgs} = prepare_request(request_spec(Request), Args),
	RequestId = request(Method, URL, Auth, NormalArgs),
	ets:insert(twerl, {RequestId, Request, From}),
    {noreply, State};

handle_call(_Request, {Client, _Tag}, State) ->
	exit(Client, unknown_twitter_request),
    {reply, ok, State}.

%% --------------------------------------------------------------------
%% Function: handle_cast/2
%% Description: Handling cast messages
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%% --------------------------------------------------------------------
handle_cast(_Request, #state{} = State) ->
    {noreply, State}.

%% --------------------------------------------------------------------
%% Function: handle_info/2
%% Description: Handling all non call/cast messages
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%% --------------------------------------------------------------------
handle_info({http, {RequestId, {{_HTTPVersion, 200, _Text}, Headers, Body}}}, State) ->
    [{_Key, Request, From}] = ets:lookup(twerl, RequestId),
    try
        case Request of
            search ->
                Response = decode_search_responses(mochijson2:decode(Body)),
                gen_server:reply(From, {ok, Response});
            xauth ->
                Params = oauth_uri:params_from_string(binary_to_list(Body)),
                Result = [{token, proplists:get_value("oauth_token", Params)},
                          {secret, proplists:get_value("oauth_token_secret", Params)},
                          {username, proplists:get_value("screen_name", Params)},
                          {user_id, proplists:get_value("user_id", Params)}],
                gen_server:reply(From, {ok, Result});
            _ ->
                Response = decode_responses(mochijson2:decode(Body)),
                Limits = [{Key, list_to_integer(Value)} || {Key, Value} <-
                            [{ratelimit_limit, proplists:get_value("x-ratelimit-limit", Headers)},
                             {ratelimit_reset, proplists:get_value("x-ratelimit-reset", Headers)},
                             {ratelimit_remaining, proplists:get_value("x-ratelimit-remaining", Headers)}], Value /= undefined],
                gen_server:reply(From, {ok, Response, Limits})
        end
    catch
        error:Exception ->
            gen_server:reply(From, {error, {exception, Exception}})
    end,
    ets:delete(twerl, RequestId),
    {noreply, State};

%% todo check ratelemit-remining
handle_info({http, {RequestId, {{_HTTPVersion, 400, _Text}, Headers, _Body}}}, State) ->
    [{_Key, _Request, From}] = ets:lookup(twerl, RequestId),
    ets:delete(twerl, RequestId),
    Limits = [{Key, list_to_integer(Value)} || {Key, Value} <-
                [{ratelimit_limit, proplists:get_value("x-ratelimit-limit", Headers)},
                 {ratelimit_reset, proplists:get_value("x-ratelimit-reset", Headers)},
                 {ratelimit_remaining, proplists:get_value("x-ratelimit-remaining", Headers)}], Value /= undefined],
    gen_server:reply(From, {error, {rate_limit, Limits}}),
    {noreply, State};

handle_info({http, {RequestId, {{_HTTPVersion, 401, _Text}, Headers, Body}}}, State) ->
    [{_Key, _Request, From}] = ets:lookup(twerl, RequestId),
    ets:delete(twerl, RequestId),
    Limits = [{Key, list_to_integer(Value)} || {Key, Value} <-
                [{ratelimit_limit, proplists:get_value("x-ratelimit-limit", Headers)},
                 {ratelimit_reset, proplists:get_value("x-ratelimit-reset", Headers)},
                 {ratelimit_remaining, proplists:get_value("x-ratelimit-remaining", Headers)}], Value /= undefined],
    gen_server:reply(From, {error, {noauth, Limits, Body}}),
    {noreply, State};

handle_info({http, {RequestId, {error, Reason}}}, State) ->
    [{_Key, _Request, From}] = ets:lookup(twerl, RequestId),
    ets:delete(twerl, RequestId),
    gen_server:reply(From, {error, Reason}),
    {noreply, State};

handle_info({http, {RequestId, {{_HTTPVersion, _Other, _Text}, _Headers, <<"{\"error\":", _/binary>> = Body}}}, State) ->
    [{_Key, _Request, From}] = ets:lookup(twerl, RequestId),
    ets:delete(twerl, RequestId),
    try mochijson2:decode(Body) of 
        {struct, Json} ->
            case proplists:get_value(<<"error">>, Json, undefined) of
                undefined ->
                    gen_server:reply(From, {error, {unexpected_response, Body}});
                Message ->
                    gen_server:reply(From, {error, {message, Message}})
            end;
        _ ->
            gen_server:reply(From, {error, {unexpected_response, Body}})
    catch
        error:_ ->
            gen_server:reply(From, {error, {unexpected_response, Body}})
    end,
    {noreply, State};

handle_info({http, {RequestId, Other}}, State) ->
    [{_Key, _Request, From}] = ets:lookup(twerl, RequestId),
    ets:delete(twerl, RequestId),
    gen_server:reply(From, {error, {unexpected_response, Other}}),
    {noreply, State}.

%% --------------------------------------------------------------------
%% Function: terminate/2
%% Description: Shutdown the server
%% Returns: any (ignored by gen_server)
%% --------------------------------------------------------------------
terminate(_Reason, #state{} = _State) ->
    ok.

%% --------------------------------------------------------------------
%% Func: code_change/3
%% Purpose: Convert process state when code is changed
%% Returns: {ok, NewState}
%% --------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% --------------------------------------------------------------------
%%% Internal functions
%% --------------------------------------------------------------------

request(get, URL, {oauth, Consumer, Token, TokenSecret}, Args) ->
    SignedParams = oauth:signed_params("GET", URL, Args, Consumer, Token, TokenSecret),
    OAuthURL = oauth:uri(URL, SignedParams),
    {ok, RequestId} = http:request(get, {OAuthURL, []}, ?HTTP_OPTIONS, [{sync, false}]),
    RequestId;
request(get, URL, {basic, User, Password}, Args) ->
	RequestURL = URL ++ "?" ++ oauth_uri:params_to_string(Args),
    {ok, RequestId} = http:request(get, {RequestURL, [http_basic_auth(User, Password)]}, ?HTTP_OPTIONS, [{sync, false}]),
    RequestId;
request(post, URL, {oauth, Consumer, Token, TokenSecret}, Args) ->
    SignedParams = oauth:signed_params("POST", URL, Args, Consumer, Token, TokenSecret),
    Post = oauth_uri:params_to_string(SignedParams),
    {ok, RequestId} = http:request(post, {URL, [], "application/x-www-form-urlencoded", Post}, ?HTTP_OPTIONS, [{sync, false}]),
    RequestId;
request(post, URL, {basic, User, Password}, Args) ->
    Post = oauth_uri:params_to_string(Args),
    {ok, RequestId} = http:request(post, {URL, [http_basic_auth(User, Password)],
										  "application/x-www-form-urlencoded", Post}, ?HTTP_OPTIONS, [{sync, false}]),
    RequestId.

request_spec(direct_messages) -> {get, ["/direct_messages"]};
request_spec(direct_messages_sent) -> {get, ["/direct_messages/sent"]};
request_spec(direct_messages_new) -> {post, ["/direct_messages/new"]};
request_spec(direct_messages_destroy) -> {post, ["/direct_messages/destroy/", id]};
request_spec(friendships_create) -> {post, ["/friendships/create/", id]};
request_spec(friendships_destroy) -> {post, ["/friendships/destroy/", id]};
request_spec(statuses_home_timeline) -> {get, ["/statuses/home_timeline"]};
request_spec(statuses_mentions) -> {get, ["/statuses/mentions"]};
request_spec(statuses_show) -> {get, ["/statuses/show/", id]};
request_spec(statuses_destroy) -> {post, ["/statuses/destroy/", id]};
request_spec(statuses_retweet) -> {post, ["/statuses/retweet/", id]};
request_spec(statuses_update) -> {post, ["/statuses/update"]};
request_spec(statuses_user_timeline) -> {get, ["/statuses/user_timeline"]};
request_spec(users_show) -> {get, ["/users/show"]};
request_spec(favorites) -> {get, ["/favorites"]};
request_spec(favorites_create) -> {post, ["/favorites/create/", id]};
request_spec(favorites_destroy) -> {post, ["/favorites/destroy/", id]}.

element_spec(<<"retweeted_status">>) -> {retweeted_status, fun({struct, Status}) -> decode_response(Status) end};
element_spec(<<"user">>) -> {user, fun({struct, User}) -> decode_user(User) end};
element_spec(<<"sender">>) -> {sender, fun({struct, User}) -> decode_user(User) end};
element_spec(<<"recipient">>) -> {recipient, fun({struct, User}) -> decode_user(User) end};
element_spec(<<"created_at">>) -> {created_at, fun(Value) -> decode_twitter_time(binary_to_list(Value)) end};
element_spec(<<"description">>) -> description;
element_spec(<<"favorited">>) -> favorited;
element_spec(<<"favourites_count">>) -> favourites_count;
element_spec(<<"followers_count">>) -> followers_count;
element_spec(<<"following">>) -> following;
element_spec(<<"friends_count">>) -> friends_count;
element_spec(<<"geo">>) -> geo;
element_spec(<<"geo_enabled">>) -> geo_enabled;
element_spec(<<"id">>) -> id;
element_spec(<<"in_reply_to_screen_name">>) -> in_reply_to_screen_name;
element_spec(<<"in_reply_to_status_id">>) -> in_reply_to_status_id;
element_spec(<<"in_reply_to_user_id">>) -> in_reply_to_user_id;
element_spec(<<"location">>) -> location;
element_spec(<<"name">>) -> name;
element_spec(<<"notifications">>) -> notifications;
element_spec(<<"profile_background_color">>) -> profile_background_color;
element_spec(<<"profile_background_image_url">>) -> profile_background_image_url;
element_spec(<<"profile_background_tile">>) -> profile_background_tile;
element_spec(<<"profile_image_url">>) -> profile_image_url;
element_spec(<<"profile_link_color">>) -> profile_link_color;
element_spec(<<"profile_sidebar_border_color">>) -> profile_sidebar_border_color;
element_spec(<<"profile_sidebar_fill_color">>) -> profile_sidebar_fill_color;
element_spec(<<"profile_text_color">>) -> profile_text_color;
element_spec(<<"protected">>) -> protected;
element_spec(<<"recipient_id">>) -> recipient_id;
element_spec(<<"recipient_screen_name">>) -> recipient_screen_name;
element_spec(<<"screen_name">>) -> screen_name;
element_spec(<<"sender_id">>) -> sender_id;
element_spec(<<"sender_screen_name">>) -> sender_screen_name;
element_spec(<<"source">>) -> source;
element_spec(<<"statuses_count">>) -> statuses_count;
element_spec(<<"text">>) -> text;
element_spec(<<"time_zone">>) -> time_zone;
element_spec(<<"truncated">>) -> truncated;
element_spec(<<"url">>) -> url;
element_spec(<<"utc_offset">>) -> utc_offset;
element_spec(<<"verified">>) -> verified;
element_spec(_) -> undefined.

search_element_spec(<<"created_at">>) -> {created_at, fun(Value) -> httpd_util:convert_request_date(binary_to_list(Value)) end};
search_element_spec(<<"from_user">>) -> from_user;
search_element_spec(<<"from_user_id">>) -> from_user_id;
search_element_spec(<<"geo">>) -> geo;
search_element_spec(<<"id">>) -> id;
search_element_spec(<<"iso_language">>) -> iso_language;
search_element_spec(<<"profile_image_url">>) -> profile_image_url;
search_element_spec(<<"source">>) -> source;
search_element_spec(<<"text">>) -> text;
search_element_spec(<<"to_user">>) -> to_user;
search_element_spec(<<"to_user_id">>) -> to_user_id;
search_element_spec(_) -> undefined.

decode_search_responses({struct, [{<<"results">>, Results} | _Details]}) ->
    [decode_search_response(Result) || {struct, Result} <- Results].

decode_search_response(Result) ->
    [decode_search_element(Name, Value) || {Name, Value} <- Result].

decode_responses({struct, Status}) ->
    decode_response(Status);
decode_responses(Responses) ->
    [decode_response(Response) || {struct, Response} <- Responses].

decode_response(Response) ->
    [decode_element(Name, Value) || {Name, Value} <- Response].

decode_element(Name, Value) ->
    decode_element_fun(Name, Value, fun element_spec/1).

decode_search_element(Name, Value) ->
    decode_element_fun(Name, Value, fun search_element_spec/1).

decode_element_fun(Name, Value, SpecFun) ->
	case SpecFun(Name) of
		undefined ->
			{Name, Value};
		{Key, Fun} ->
			{Key, Fun(Value)};
		Key ->
			{Key, Value}
	end.

decode_user(User) ->
    [decode_element(Name, Value) || {Name, Value} <- User].

decode_twitter_time([_D,_A,_Y, _SP, M, O, N, _SP, D1, D2, _SP, H1, H2, $:, M1, M2, $:, S1, S2, _SP, $+, $0, $0, $0, $0, _SP,Y1, Y2, Y3, Y4 | _Rest]) ->
    Year = list_to_integer([Y1, Y2, Y3, Y4]),
    Month = http_util:convert_month([M, O, N]),
    Day = list_to_integer([D1, D2]),
    Hour = list_to_integer([H1, H2]),
    Minute = list_to_integer([M1, M2]),
    Second = list_to_integer([S1, S2]),
    {{Year, Month, Day}, {Hour, Minute, Second}}.

prepare_request(Spec, Args) ->
	{Method, PathSpec} = Spec,
	PathKeys = [Element || Element <- PathSpec, is_atom(Element)],
	{PathArgs, NormalArgs} = lists:partition(fun({Key, _}) -> proplists:get_bool(Key, PathKeys) end, Args),
	URL = build_path(PathSpec, PathArgs, []),
	NormalArgs2 = [{to_list(Key), to_list(Value)} || {Key, Value} <- NormalArgs],
	{Method, URL, NormalArgs2}.

build_path([], _PathArgs, Acc) ->
	?BASE ++ lists:flatten(lists:reverse([".json" | Acc]));
build_path([Element | Rest], PathArgs, Acc) when is_atom(Element) ->
	build_path(Rest, PathArgs, [to_list(proplists:get_value(Element, PathArgs)) | Acc]);
build_path([Element | Rest], PathArgs, Acc) when is_list(Element) ->
	build_path(Rest, PathArgs, [Element | Acc]).

to_list(V) when is_list(V) ->
    V;
to_list(V) when is_atom(V) ->
    atom_to_list(V);
to_list(V) when is_binary(V) ->
    binary_to_list(V);
to_list(V) when is_integer(V) ->
    integer_to_list(V).

http_basic_auth(User, Password) ->
	UserPasswd = base64:encode_to_string(User ++ ":" ++ Password),
	{"authorization", "Basic " ++ UserPasswd}.
