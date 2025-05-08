# Jenkins to K8s deployment using TF

## Order of use:
1. k8s-aws-infra - do `terraform apply`, to create base infrastructure, eks cluster and jenkins server
2. k8s-yaml - in `k8s-yaml/ingress.yaml` set subnets in field `alb.ingress.kubernetes.io/subnets` and cert arn in field `alb.ingress.kubernetes.io/certificate-arn` , commit and push to git, will be used by jenkins pipeline to create/delete k8s resources 
4. jenkins-pipelines - this is the pipelines code, that should be used once the jenkins server is up. Once it's up you'll need:
   1. set global credentials with GitHub personal access token (Credentials type)
   2. set global credentials with AWS access and secret key (Secret text type)
   3. create 2 pipelines with the code from `jenkins-pipelines/apply` and `jenkins-pipelines/delete`
   4. run first apply pipeline to deploy our nginx deployment that will be exposed as dns name devapi.niks.cloud 
5. k8s-aws-infra - update r53.tf with the correct ALB DNS that will be provisioned by jenkins pipeline in the previous step and do `terraform apply` again


## Important notice about working with NAT instances

Once this repo is cloned from GitHub, before doing `terraform apply` make sure to check Line Separators for .sh scripts in `modules/nat` they should be using linux format equal to`LF`.
Otherwise, you have a risk of facing weird issues when userdata script will fail and, as a result, Network Interface with EIP tied to it will not be attached to the newly created NAT instance.

Also, make sure not to do Instance Refresh for ASG used for NAT instance when the new instance is being created before the old one is deleted - unless Network Interface isn't unattached from the old instance, the new one won't be able to attach it, script that's doing it will fail.