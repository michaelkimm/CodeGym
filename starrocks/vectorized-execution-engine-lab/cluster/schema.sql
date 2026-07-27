CREATE DATABASE IF NOT EXISTS vector_lab;
USE vector_lab;

CREATE TABLE IF NOT EXISTS user_chats (
  chat_id BIGINT NOT NULL,
  channel_id INT NOT NULL,
  status VARCHAR(16) NOT NULL
)
PRIMARY KEY (chat_id)
DISTRIBUTED BY HASH(chat_id) BUCKETS 4
PROPERTIES ("replication_num" = "1");
