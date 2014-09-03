% VALIDITY = end of support in rounded half megasecs since epoch
% VALIDITY resolution is 2^19 seconds = 6 days
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
%  20140906 fails on 20140912 at 07h34
%
% compile with erlc -DVALIDITY=2824

-ifndef(VALIDITY)
-define(VALIDITY, 0).
-endif.
