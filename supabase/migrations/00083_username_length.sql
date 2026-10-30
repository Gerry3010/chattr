-- Usernames get an upper limit.
--
-- The occasion (2026-08-29, found on 2026-09-03): an iOS device created an
-- account with a **5469 character** username — the content of a pasted
-- documentation page. Not an attack, a paste accident: the account has zero
-- chats and has been dead since, like most of them from the TestFlight funnel.
--
-- The gap sat in the UI, and in the worse half of it: the RENAME field had long
-- limited to 40 characters, the CREATION field on the sign-in screen to nothing
-- at all. That is where the name comes into being.
--
-- Why a guarantee is nevertheless needed here: the UI is convenience, not
-- protection. An old client, a direct call or the next screen somebody builds
-- gets past it — the database does not. The name travels through push
-- notifications, mentions and every member list; an unbounded string in it is
-- an open flank.
--
-- 40 characters, because that is the number the rename field already used
-- (`kMaxUsernameLength` in lib/features/profile/username_rules.dart). Inventing
-- a new number would have broken existing names without gaining anything.

-- 1. Fit existing names in. As measured on 2026-09-03 this affects EXACTLY ONE row
--    of 72 (the 5469 characters); all the others are under 32. Truncate rather than
--    delete: the account belongs to somebody, even if it was never used.
UPDATE public.profiles
   SET username = left(username, 40)
 WHERE char_length(username) > 40;

-- 2. And from now on it applies. NOT NULL has been there since 00001; what is added
--    here is that the name may be neither empty nor endless.
ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_username_length
  CHECK (char_length(btrim(username)) BETWEEN 1 AND 40);
