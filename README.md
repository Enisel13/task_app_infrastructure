# Task app infrastructure on Google Cloud

Terraform provisions a custom VPC, separate public and private subnets, Cloud
NAT, a private-node GKE cluster, and a private Cloud SQL for MySQL instance.
The database has no public IP, requires encrypted connections, uses a dedicated
application user, and has automated backups enabled.

**Keep the Azure and GCP Terraform states separate.** This checkout's local
default workspace already has Azure resource addresses in its state. Do not
run a GCP plan or apply in the `default` workspace: Terraform could propose
destroying those Azure resources. Use the dedicated `gcp` workspace below.

Google Cloud does not mark a subnet as "public" or "private." The public subnet
is reserved for resources that you intentionally expose; the GKE nodes live in
the private subnet and use Cloud NAT for outbound access. Expose the application
through a GKE Ingress or Gateway rather than assigning public IPs to nodes.
Cloud SQL uses Private Service Access on the VPC and is reachable by applications
running in that VPC.

The GKE control plane has a public endpoint restricted to the public IPv4
address of the machine running Terraform. Terraform discovers that address
through `api.ipify.org` when planning, so that endpoint must be reachable and
the workstation should be the one from which you later run `kubectl`. The
default configuration uses one zonal GKE node and the low-cost `db-f1-micro`
Cloud SQL tier to reduce initial resource use; these are development defaults,
not production sizing. GKE, Cloud SQL, networking, and outbound traffic can
incur charges.

## Authenticate to Google Cloud with the CLI

Install the Google Cloud CLI (`gcloud`), sign in, select your project, and set
up Application Default Credentials (ADC), which the Terraform Google provider
uses:

```sh
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
gcloud auth application-default login
gcloud config get-value project
```

The project ID is prefilled in `variables.tf`, so no `terraform.tfvars` input is
required. If you use a different project, update that default. Make sure the
same project is selected in `gcloud` and has billing enabled.

In the Google Cloud Console, make sure billing is enabled for the project and
check that the selected region has sufficient Compute Engine and GKE quota.
Your account needs permission to enable APIs, create networking/GKE/Cloud SQL
resources, and create service accounts and IAM bindings. Enable the Service
Usage API once if it is not already enabled:

```sh
gcloud services enable serviceusage.googleapis.com --project=YOUR_PROJECT_ID
```

For CI/CD, prefer Workload Identity Federation over downloading or storing a
service-account key. Do not commit credentials, passwords, Terraform state, or
`terraform.tfvars`.

## Configure and deploy

Run Terraform from this directory; the project ID and all infrastructure
settings have defaults, the workstation CIDR is discovered automatically, and
Terraform generates the database password:

```sh
terraform init
terraform workspace new gcp
terraform fmt -recursive
terraform validate
terraform plan
terraform apply
```

If the `gcp` workspace already exists, use `terraform workspace select gcp`
instead of creating it.

Review the plan before applying. Terraform enables the required Resource
Manager, Compute Engine, GKE, IAM, Cloud SQL Admin, and Service Networking
APIs.

Configure `kubectl` for the new cluster:

```sh
terraform output -raw gke_get_credentials_command
```

Copy and run the printed command, then verify access:

```sh
kubectl get nodes
```

Deploy your Kubernetes manifests or Helm chart to this cluster. Configure the
application to connect to the Cloud SQL private IP shown by
`terraform output database_private_ip`, using the database name
`terraform output -raw database_name` and username `task_app`. Retrieve the
generated password only when needed with
`terraform output -raw database_password`; provide it to your app via a
Kubernetes Secret or Secret Manager. Avoid pasting it into source files,
container images, or shell history. The application must run inside the VPC
(for example, in GKE) to reach the database's private IP.

## State and cleanup

Terraform state contains sensitive values, including the database password.
Keep local state private; for team or production use, configure a restricted,
versioned Cloud Storage backend before applying.

Cloud SQL deletion protection is enabled by default. To intentionally destroy
the infrastructure, first set `database_deletion_protection = false` in your
local `terraform.tfvars` and apply that change. Then run `terraform destroy`
and review the deletion plan carefully.
