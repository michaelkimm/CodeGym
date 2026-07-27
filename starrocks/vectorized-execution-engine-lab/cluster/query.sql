SELECT VERSION() AS mysql_compatibility,
       CURRENT_VERSION() AS starrocks_version;
USE vector_lab;
SELECT COUNT(*) AS loaded_rows FROM user_chats;

EXPLAIN VERBOSE
SELECT channel_id, COUNT(*) AS open_chat_count
FROM user_chats
WHERE status = 'OPEN'
GROUP BY channel_id
ORDER BY channel_id;

SET enable_profile = true;
SELECT channel_id, COUNT(*) AS open_chat_count
FROM user_chats
WHERE status = 'OPEN'
GROUP BY channel_id
ORDER BY channel_id;
SELECT last_query_id() AS profile_query_id;
