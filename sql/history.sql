DROP TABLE IF EXISTS jid_map;
DROP TABLE IF EXISTS collection_map;
DROP TABLE IF EXISTS messages;
DROP TABLE IF EXISTS deliver_status;
DROP VIEW IF EXISTS messages_view;
DROP PROCEDURE IF EXISTS log_msg;
DROP PROCEDURE IF EXISTS set_read;
DROP PROCEDURE IF EXISTS remove_user_history;
DROP PROCEDURE IF EXISTS remove_conversation_history;
DROP PROCEDURE IF EXISTS set_deliver_status;


/* SET table_type=InnoDB; */


CREATE TABLE jid_map (
	id INT UNSIGNED PRIMARY KEY AUTO_INCREMENT,
	jid VARCHAR(256)
);
CREATE UNIQUE INDEX i_jid_map ON jid_map(jid(128));

CREATE TABLE collection_map (
	id INT UNSIGNED PRIMARY KEY AUTO_INCREMENT,
	collection text NOT NULL
);
CREATE UNIQUE INDEX i_collection_map ON collection_map(collection(128));


CREATE TABLE deliver_status (
    id INT UNSIGNED PRIMARY KEY,
    status TEXT
);


/**
* Read status of sent messages.  We keep only the "highest" one. (if targetA has received and targetB has read, we keep "read")
*
*/
INSERT IGNORE INTO deliver_status(id, status) values (0, 'unknown');
INSERT IGNORE INTO deliver_status(id, status) values (1, 'unreliable');
INSERT IGNORE INTO deliver_status(id, status) values (2, 'offline');
INSERT IGNORE INTO deliver_status(id, status) values (3, 'delayed');
INSERT IGNORE INTO deliver_status(id, status) values (4, 'received');
INSERT IGNORE INTO deliver_status(id, status) values (5, 'read');


CREATE TABLE messages (
	user INT UNSIGNED NOT NULL,
	id VARCHAR(256) NOT NULL,
	sender INT UNSIGNED  NOT NULL,
	collection  INT UNSIGNED NOT NULL,
	message TEXT NOT NULL,
	at DATETIME NOT NULL,
        modified DATETIME NOT NULL,
	is_read BOOL NOT NULL,
        deliver_status INT UNSIGNED NOT NULL
);

CREATE INDEX i_messages_modified on messages(user,modified);
CREATE INDEX i_messages_id on messages(user,id(16));
CREATE INDEX i_messages_collection on messages(user,collection);



DELIMITER $$
CREATE OR REPLACE VIEW messages_view AS
	SELECT 	user.jid as jid, 
		sender.jid as sender, 
		c.collection as collection,
		m.message as message,
		m.id as id,
		m.at as at,
                m.modified as modified,
		m.is_read as is_read,
                d.status as deliver_status
	FROM messages m, jid_map user, jid_map sender, collection_map c, deliver_status d
        WHERE
		m.user = user.id AND 
		m.sender = sender.id AND
		m.collection = c.id AND
                m.deliver_status = d.id
	ORDER BY m.at ASC$$


CREATE PROCEDURE log_msg(IN user_in TEXT CHARACTER SET utf8, IN sender_in TEXT CHARACTER SET utf8, IN collection_in TEXT CHARACTER SET utf8, IN msg_id_in TEXT, IN message_in TEXT CHARACTER SET utf8, IN at_in DATETIME, IN is_read_in BOOLEAN)
	BEGIN
		DECLARE userID INT UNSIGNED;
		DECLARE senderID INT UNSIGNED;
		DECLARE collectionID INT UNSIGNED;
                DECLARE deliverStatusId INT UNSIGNED;
		SELECT id INTO userID FROM jid_map where jid = user_in;
		IF userID IS NULL THEN
			INSERT INTO jid_map VALUES(NULL, user_in);
			SET userID = LAST_INSERT_ID();
		END IF;
		SELECT id INTO senderID FROM jid_map where jid = sender_in;
		IF senderID IS NULL THEN
			INSERT INTO jid_map VALUES (NULL, sender_in);
			SET senderID = LAST_INSERT_ID();
		END IF;
		SELECT id INTO collectionID FROM collection_map where collection = collection_in;
		IF collectionID IS NULL THEN
			INSERT INTO collection_map VALUES (NULL, collection_in);
			SET collectionID = LAST_INSERT_ID();
		END IF;
                select id into deliverStatusId from deliver_status where status = 'unknown';
		INSERT INTO messages(user, sender,id, collection, message, at, modified, is_read, deliver_status) 
			VALUES (
				userID, senderID, msg_id_in, collectionID, message_in, at_in, at_in, is_read_in, deliverStatusId
			);
	END$$


/* To mark a message as read, do it in two steps:
*  First try to do it with a restriction on date (last 24h) so to only hit the latest partition
*  if that didn't work (message was older), do it without restriction
*/
CREATE PROCEDURE set_read(IN user_jid_in TEXT CHARACTER SET utf8, IN msgID_in TEXT, IN dd_in DATETIME)
	BEGIN
	DECLARE c INT;
        DECLARE userID INT UNSIGNED;
	SELECT id into userID FROM jid_map where jid = user_jid_in;
	SELECT count(*) into c from messages where id = msgID_in and user = userID and modified > (NOW() - INTERVAL 24 HOUR); 
	IF c > 0 THEN
		UPDATE messages SET is_read=true, modified = dd_in  WHERE id = msgID_in and user = userID and modified > (NOW() - INTERVAL 24 HOUR);
	ELSE
		UPDATE messages SET is_read=true, modified = dd_in WHERE user = userID and id = msgID_in;
	END IF;
	END$$


CREATE PROCEDURE remove_conversation_history(IN user_jid_in TEXT CHARACTER SET utf8, IN conversation_in TEXT CHARACTER SET utf8)
    BEGIN
    DECLARE userID INT UNSIGNED;
    DECLARE collectionID INT UNSIGNED;
    SELECT id into userID FROM jid_map where jid = user_jid_in;
    SELECT id INTO collectionID FROM collection_map where collection = conversation_in;
    DELETE from messages where user = userID and collection = collectionID;
    END$$


CREATE PROCEDURE remove_user_history(IN user_jid_in TEXT CHARACTER SET utf8)
    BEGIN
    DECLARE userID INT UNSIGNED;
    SELECT id into userID FROM jid_map where jid = user_jid_in;
    DELETE from messages where user = userID; 
    END$$



/** 
*  We will receive many deliver status events (and for each target). 
*  Only keep 1,  the more "advanced" one for the conversation.
*/
CREATE PROCEDURE set_deliver_status(IN user_jid_in TEXT CHARACTER SET utf8, IN msgID_in TEXT, IN status_in TEXT, IN dd_in DATETIME)
	BEGIN
	DECLARE c INT;
        DECLARE userID INT UNSIGNED;
        DECLARE statusNumber INT UNSIGNED;
        DECLARE previousStatusNumber INT UNSIGNED;
	SELECT id into userID FROM jid_map where jid = user_jid_in;
        select id into statusNumber from deliver_status where status = status_in;
	SELECT count(*) into c from messages where id = msgID_in and user = userID and modified > (NOW() - INTERVAL 24 HOUR); 
        IF c > 0 THEN
            UPDATE messages SET deliver_status = statusNumber, modified = dd_in  
                WHERE id = msgID_in and user = userID and modified > (NOW() - INTERVAL 24 HOUR) and deliver_status < statusNumber;
        ELSE
            UPDATE messages SET deliver_status = statusNumber, modified = dd_in WHERE user = userID and id = msgID_in and deliver_status < statusNumber;
        END IF;
	END$$
