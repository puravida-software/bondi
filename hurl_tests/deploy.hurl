POST {{host}}/api/v1/deploy
Content-Type: application/json
{
  "service_name": "grokkr",
  "env_vars": {
    "DATABASE_URL": "my_database_url"
  },
  "image": "registry.gitlab.com/puravida.software/grokkr-py:run-status",
  "port": 8080,
  "registry_pass": "my_registry_pass",
  "registry_user": "miguellova@gmail.com",
  "traefik_acme_email": "miguel@grokkr.app",
  "traefik_domain_name": "grokkr.app",
  "traefik_image": "traefik:v3.3.3"
}

HTTP 200
