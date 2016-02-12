% VALIDITY = end of support in rounded half megasecs since epoch, and max number in cluster nodes
% VALIDITY datetime resolution is 2^19 seconds = 6 days, coded on 14 lower bits
%
% example:
%  - last day of support is 2014/09/31
%  - seconds since epoch: date -j +%s 093123592014 -> 1412200740
%  - half megasecs: 1412<<1 + 200740>>19 -> 2824
%  - VALIDITY=2824
%
%  at best, VALIDITY fails few hours after day change
%  at worst, it fails after 6 days
% example:
%  20140905 fails on 20140906 at 12h40
%  20140906 fails on 20140912 at 10h54
%
% compile with erlc -DVALIDITY=2824, or configure --with-licence=20140931
% default is unlimited licence (9999 ends in 2128)
%
% number of allowed cluster node is coded on higher bits starting at 14th bit
% default is unlimited licence (0 nodes)

-ifndef(VALIDITY).
-define(VALIDITY, 9999).
-endif.

-define(CHECK_EXPIRATION(Ms, Ss),
        (((Ms) bsl 1) + ((Ss) bsr 19) =< ?VALIDITY band 16#3FFF)).

-define(CHECK_NODES(N),
        ((?VALIDITY bsr 14 == 0) orelse ((N) < ?VALIDITY bsr 14))).
