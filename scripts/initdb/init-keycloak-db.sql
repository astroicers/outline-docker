-- Create keycloak database if not exists
SELECT 'CREATE DATABASE keycloak OWNER outline'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'keycloak')\gexec
