
## EKS Console visibility for non-creator IAM users

When logging in with `devops-admin` IAM user, the EKS cluster was
not visible in the AWS Console even though kubectl access worked
fine. Root cause analysis:

1. Even with `AdministratorAccess` IAM policy, EKS Console UI
   requires explicit `EKS Access Entry + Cluster Access Policy`
   binding for the IAM principal.
2. After `associate-access-policy` (binding
   `AmazonEKSClusterAdminPolicy`), Console still showed nothing.
3. Final root cause: Console region selector was on the wrong
   region. EKS is a region-scoped service; clusters in ap-east-1
   only show when Console is set to ap-east-1.

Fix: switch Console region to ap-east-1 (top-right selector).
