-- End-to-end encrypted push. A notification's text is now sealed on the
-- computer with its channel key, which only the phones that scanned its code
-- hold; functions/push forwards the ciphertext to the relay without reading
-- it. The per-phone key this server sealed with before goes. A followed
-- session's push (activity_tokens) carries a state only, unencrypted, on
-- iPhones and Android phones alike.
alter table public.push_devices drop column key;
