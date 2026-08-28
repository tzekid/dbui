PRAGMA user_version = 7;
PRAGMA application_id = 1145197909;

CREATE TABLE users (
    id INTEGER PRIMARY KEY,
    email TEXT NOT NULL UNIQUE,
    active INTEGER,
    score REAL,
    notes TEXT,
    payload BLOB,
    created_at TEXT NOT NULL
) STRICT;

CREATE TABLE memberships (
    tenant_id TEXT NOT NULL,
    user_id INTEGER NOT NULL,
    role TEXT NOT NULL,
    PRIMARY KEY (tenant_id, user_id)
) WITHOUT ROWID;

CREATE TABLE generated_values (
    id INTEGER PRIMARY KEY,
    base INTEGER,
    doubled INTEGER GENERATED ALWAYS AS (base * 2)
);

CREATE TABLE no_primary_key (
    value TEXT,
    other_value INTEGER
);

CREATE TABLE empty_table (
    id INTEGER PRIMARY KEY,
    value TEXT
) STRICT;

CREATE TABLE text_keys (
    code TEXT PRIMARY KEY,
    value TEXT
) STRICT;

CREATE TABLE blob_keys (
    id BLOB PRIMARY KEY,
    value TEXT
) WITHOUT ROWID, STRICT;

CREATE TABLE nullable_composite (
    left_key TEXT,
    right_key TEXT,
    value TEXT,
    PRIMARY KEY (left_key, right_key)
);

CREATE TABLE "odd table" (
    "select" TEXT,
    "quote""name" TEXT
);

CREATE VIEW active_users AS
SELECT id, email, created_at
FROM users
WHERE active = 1;

CREATE INDEX users_created_at_idx ON users(created_at);

CREATE TRIGGER users_created_at_guard
BEFORE UPDATE OF created_at ON users
BEGIN
    SELECT RAISE(ABORT, 'created_at is immutable');
END;

INSERT INTO users(email, active, score, notes, payload, created_at) VALUES
    ('empty@example.test', 1, 1.5, '', x'', '2026-08-28T10:00:00Z'),
    ('null@example.test', 0, NULL, NULL, NULL, '2026-08-28T10:01:00Z'),
    ('markup@example.test', 1, -42.25, '<script>alert("stored")</script>', x'89504E470D0A1A0A', '2026-08-28T10:02:00Z'),
    ('unicode@example.test', 1, 9007199254740991, 'Здравствуйте · 你好 · مرحبا', zeroblob(8192), '2026-08-28T10:03:00Z'),
    ('invalid@example.test', 1, 0.0, CAST(x'80FF' AS TEXT), randomblob(128), '2026-08-28T10:04:00Z');

WITH RECURSIVE generated(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM generated WHERE n < 30
)
INSERT INTO users(email, active, score, notes, payload, created_at)
SELECT
    printf('page-%02d@example.test', n),
    n % 2,
    n / 3.0,
    printf('generated row %d', n),
    randomblob(n),
    printf('2026-08-28T11:%02d:00Z', n)
FROM generated;

UPDATE users
SET notes = replace(hex(zeroblob(1000)), '00', 'x')
WHERE email = 'page-30@example.test';

INSERT INTO memberships VALUES
    ('alpha', 1, 'owner'),
    ('alpha', 2, 'member'),
    ('βeta', 1, 'reader');

INSERT INTO generated_values(id, base) VALUES (1, 21);
INSERT INTO no_primary_key VALUES (NULL, -7), ('', 99);
INSERT INTO "odd table" VALUES ('keyword', 'quoted identifier');
INSERT INTO text_keys VALUES ('alpha/key', 'text primary key');
INSERT INTO blob_keys VALUES (x'00FF1020', 'blob primary key');
INSERT INTO nullable_composite VALUES (NULL, 'right', 'not structurally editable');
