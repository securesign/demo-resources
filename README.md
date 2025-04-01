# RHTAS Demo and Testing Resources

This repository contains OpenShift/Kubernetes resources used
for demonstrating installation and configuration of the Red Hat
Trusted Artifact Signer. It is recommended that these resources
be used on a "clean" cluster, before installing RHTAS.

Currently, the only resource provided by this repository is
Keycloak. To use these Keycloak resources you simply need to
use the following two commands.

```
oc create -k https://github.com/securesign/sigstore-ocp/keycloak/operator/base
oc create -k https://github.com/securesign/sigstore-ocp/keycloak/resources/base
```

This should install the Keycloak operator, and create a new
user with the email `jdoe@redhat.com` and a password of
`password`. Once installed, you should be able to set Keycloak
as your OIDC provider when installing RHTAS.

