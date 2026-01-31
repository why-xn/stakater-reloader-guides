# Vault policy for ESO Token authentication
# Grants read access to the myapp KV v2 secret

path "secret/data/myapp" {
  capabilities = ["read"]
}

path "secret/metadata/myapp" {
  capabilities = ["read"]
}
