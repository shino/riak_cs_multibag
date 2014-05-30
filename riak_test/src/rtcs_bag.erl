%% Copyright (c) 2014 Basho Technologies, Inc.  All Rights Reserved.

-module(rtcs_bag).

-compile(export_all).
-include_lib("eunit/include/eunit.hrl").
-include("riak_cs.hrl").

%% Setup utilities

configs(MultiBags) ->
    rtcs:configs(
      [{cs, rtcs:cs_config([], [{riak_cs_multibag, [{bags, MultiBags}]}])},
       {stanchion, rtcs:stanchion_config([{bags, MultiBags}])}]).

set_weights(Weights) ->
    [bag_weight(1, Kind, BagId, Weight) || {Kind, BagId, Weight} <- Weights].

multibagcmd(Path, N, Args) ->
    lists:flatten(io_lib:format("~s-multibag ~s", [rtcs:riakcs_binpath(Path, N), Args])).

bag_weight(N, Kind, BagId, Weight) ->
    SubCmd = case Kind of
                 all ->      "weight";
                 manifest -> "weight-manifest";
                 block ->    "weight-block"
             end,
    Cmd = multibagcmd(rt_config:get(rtcs:cs_current()), N,
                             io_lib:format("~s ~s ~B", [SubCmd, BagId, Weight])),
    lager:info("Running ~s", [Cmd]),
    rt:cmd(Cmd).

bag_refresh(N) ->
    Cmd = multibagcmd(rt_config:get(rtcs:cs_current()), N, "refresh"),
    lager:info("Running ~p", [Cmd]),
    rt:cmd(Cmd).

%% Assertion utilities

assert_object_in_expected_bag(Bucket, Key, UploadType,
                              AllBags, ExpectedManifestBags, ExpectedBlockBags) ->
    {UUID, M} = assert_manifest_in_single_bag(Bucket, Key,
                                             ExpectedManifestBags,
                                             AllBags -- ExpectedManifestBags),
    ok = assert_block_in_single_bag(Bucket, {UUID, M}, UploadType,
                                    ExpectedBlockBags, AllBags -- ExpectedBlockBags),
    ok.

assert_manifest_in_single_bag(Bucket, Key, ExpectedBags, NotExistingBags) ->
    RiakBucket = <<"0o:", (stanchion_utils:md5(Bucket))/binary>>,
    case assert_only_in_single_bag(ExpectedBags, NotExistingBags, RiakBucket, Key) of
        {error, Reason} ->
            lager:error("assert_manifest_in_single_bag for ~w/~w error: ~p",
                        [Bucket, Key, Reason]),
            {error, {Bucket, Key, Reason}};
        Object ->
            [[{UUID, M}]] = [binary_to_term(V) || V <- riakc_obj:get_values(Object)],
            {UUID, M}
    end.

assert_block_in_single_bag(Bucket, {UUID, Manifest}, UploadType,
                           ExpectedBags, NotExistingBags) ->
    RiakBucket = <<"0b:", (stanchion_utils:md5(Bucket))/binary>>,
    RiakKey = case UploadType of
                  normal ->
                      <<UUID/binary, 0:32>>;
                  multipart ->
                      %% Take UUID of the first block of the first part manifest
                      MpM = proplists:get_value(multipart, Manifest?MANIFEST.props),
                      PartUUID = (hd(MpM?MULTIPART_MANIFEST.parts))?PART_MANIFEST.part_id,
                      <<PartUUID/binary, 0:32>>
              end,
    case assert_only_in_single_bag(ExpectedBags, NotExistingBags,
                                   RiakBucket, RiakKey) of
        {error, Reason} ->
            lager:error("assert_block_in_single_bag for ~w/~w[~w] error: ~p",
                        [Bucket, UUID, UploadType, Reason]),
            {error, {Bucket, {UploadType, UUID, Manifest}, Reason}};
        _Object ->
            ok
    end.


-spec assert_only_in_single_bag(ExpectedBags::[binary()], NotExistingBags::[binary()],
                                RiakBucket::binary(), RiakKey::binary()) ->
                                       riakc_obj:riakc_obj().
%% Assert BKey
%% - exists onc and only one bag in ExpectedBags and
%% - does not exists in NotExistingBags.
%% Also returns a riak object which is found in ExpectedBags.
assert_only_in_single_bag(ExpectedBags, NotExistingBags, RiakBucket, RiakKey) ->
    case assert_in_expected_bags(ExpectedBags, RiakBucket, RiakKey, []) of
        {error, Reason} ->
            {error, Reason};
        Obj ->
            case assert_not_in_other_bags(NotExistingBags, RiakBucket, RiakKey) of
                {error, Reason2} ->
                    {error, Reason2};
                _ ->
                    Obj
            end
    end.

assert_in_expected_bags([], _RiakBucket, _RiakKey, []) ->
    not_found_in_expected_bags;
assert_in_expected_bags([], _RiakBucket, _RiakKey, [Val]) ->
    Val;
assert_in_expected_bags([ExpectedBag | Rest], RiakBucket, RiakKey, Acc) ->
    case get_riakc_obj(ExpectedBag, RiakBucket, RiakKey) of
        {ok, Object} ->
            lager:info("~p/~p is found at ~s", [RiakBucket, RiakKey, ExpectedBag]),
            assert_in_expected_bags(Rest, RiakBucket, RiakKey, [Object|Acc]);
        {error, notfound} ->
            assert_in_expected_bags(Rest, RiakBucket, RiakKey, Acc)
    end.

assert_not_in_other_bags([], _RiakBucket, _RiakKey) ->
    ok;
assert_not_in_other_bags([NotExistingBag | Rest], RiakBucket, RiakKey) ->
    case get_riakc_obj(NotExistingBag, RiakBucket, RiakKey) of
        {error, notfound} ->
            assert_not_in_other_bags(Rest, RiakBucket, RiakKey);
        Res ->
            lager:info("~p/~p is found at ~s", [RiakBucket, RiakKey, NotExistingBag]),
            {error, {found_in_unexpected_bag, NotExistingBag, Res}}
    end.

get_riakc_obj(Bag, B, K) ->
    Riakc = rt:pbc(Bag),
    Result = riakc_pb_socket:get(Riakc, B, K),
    riakc_pb_socket:stop(Riakc),
    Result.
