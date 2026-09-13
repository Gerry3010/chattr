-- ============================================================================
-- 00032: Re-attach the reaction broadcast trigger (prod drift)
-- ----------------------------------------------------------------------------
-- Found 2026-07-11 while debugging "reactions only appear after reopening the
-- chat": prod had the notify_reaction_change() FUNCTION (00011) but NO trigger
-- on message_reactions — a full trigger diff local↔prod showed exactly this
-- one missing. Without it, no reactionChanged event is ever broadcast: the
-- actor sees their reaction via chatview's optimistic local update, everyone
-- else only via the on-open priming fetch. Recreate idempotently.
-- ============================================================================

DROP TRIGGER IF EXISTS notify_reaction_change_trigger ON message_reactions;
CREATE TRIGGER notify_reaction_change_trigger
  AFTER INSERT OR DELETE ON message_reactions
  FOR EACH ROW
  EXECUTE FUNCTION notify_reaction_change();
