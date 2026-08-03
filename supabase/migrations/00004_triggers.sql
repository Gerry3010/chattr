-- ============================================================================
-- Database Triggers
-- ============================================================================
-- This migration creates all triggers that connect functions to table events
-- ============================================================================

-- ============================================================================
-- PART 1: Chats Table Triggers
-- ============================================================================

-- Automatically set creator as admin when chat is created
CREATE TRIGGER chat_creator_admin_trigger
BEFORE INSERT ON chats
FOR EACH ROW
EXECUTE FUNCTION set_creator_as_admin();

-- Automatically update updated_at timestamp
CREATE TRIGGER chats_updated_at_trigger
BEFORE UPDATE ON chats
FOR EACH ROW
EXECUTE FUNCTION update_chats_updated_at();

-- Notify members when chat is updated
CREATE TRIGGER chat_update_trigger
AFTER UPDATE ON chats
FOR EACH ROW
EXECUTE FUNCTION notify_chat_update();

-- Notify members before chat is deleted
CREATE TRIGGER chat_delete_trigger
BEFORE DELETE ON chats
FOR EACH ROW
EXECUTE FUNCTION notify_chat_delete();

-- ============================================================================
-- PART 2: Chat Members Table Triggers
-- ============================================================================

-- Automatically update updated_at timestamp
CREATE TRIGGER chat_members_updated_at_trigger
BEFORE UPDATE ON chat_members
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

-- Notify new member when they are added to a chat
CREATE TRIGGER new_chat_member_trigger
AFTER INSERT ON chat_members
FOR EACH ROW
EXECUTE FUNCTION broadcast_new_chat_member();

COMMENT ON TRIGGER new_chat_member_trigger ON chat_members IS 'Fires when a new member is added to a chat, notifying the user via pg_notify';

-- Notify all members about membership changes (joined/left) and create system messages
CREATE TRIGGER notify_membership_change_trigger
AFTER INSERT OR DELETE ON chat_members
FOR EACH ROW
EXECUTE FUNCTION notify_membership_change();

-- Reassign admin when an admin leaves
CREATE TRIGGER chat_member_leave_trigger
AFTER DELETE ON chat_members
FOR EACH ROW
EXECUTE FUNCTION reassign_admin_on_leave();

-- Notify removed user that they should delete the chat locally
CREATE TRIGGER notify_chat_deleted_trigger
AFTER DELETE ON chat_members
FOR EACH ROW
EXECUTE FUNCTION notify_chat_deleted_on_member_removal();

COMMENT ON TRIGGER notify_chat_deleted_trigger ON chat_members IS 'Sends chatDeleted event when a user is removed from chat_members';

-- ============================================================================
-- PART 3: Pending Chat Members Table Triggers
-- ============================================================================

-- Automatically update updated_at timestamp
CREATE TRIGGER pending_members_updated_at_trigger
BEFORE UPDATE ON pending_chat_members
FOR EACH ROW
EXECUTE FUNCTION update_pending_members_updated_at();

-- Notify admins when a user requests to join
CREATE TRIGGER notify_admins_pending_member_trigger
AFTER INSERT ON pending_chat_members
FOR EACH ROW
EXECUTE FUNCTION notify_admins_pending_member();

-- ============================================================================
-- PART 4: Messages Table Triggers
-- ============================================================================

-- Automatically update updated_at timestamp
CREATE TRIGGER messages_updated_at_trigger
BEFORE UPDATE ON messages
FOR EACH ROW
EXECUTE FUNCTION update_messages_updated_at();

-- Notify recipient when a new message is inserted
CREATE TRIGGER notify_members_new_message_trigger
AFTER INSERT ON messages
FOR EACH ROW
EXECUTE FUNCTION notify_members_new_message();

COMMENT ON TRIGGER notify_members_new_message_trigger ON messages IS 'Fires when a new message is inserted, notifying all chat members';

-- Notify sender when message status is updated
CREATE TRIGGER message_update_trigger
AFTER UPDATE ON messages
FOR EACH ROW
EXECUTE FUNCTION notify_message_update();

-- Notify members when a message is deleted
CREATE TRIGGER message_delete_trigger
BEFORE DELETE ON messages
FOR EACH ROW
EXECUTE FUNCTION notify_message_delete();
