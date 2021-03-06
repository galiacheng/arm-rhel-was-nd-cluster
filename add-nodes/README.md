# Add additional nodes to the exsiting cluster

## Prerequisites
 - Register an [Azure subscription](https://azure.microsoft.com/en-us/)
 - Register an [IBM id](https://idaas.iam.ibm.com/idaas/mtfim/sps/authsvc?PolicyId=urn:ibm:security:authentication:asf:basicldapuser)
 - Download [IBM Installation Manager Installation Kit V1.9](https://www-945.ibm.com/support/fixcentral/swg/downloadFixes?parent=ibm%7ERational&product=ibm/Rational/IBM+Installation+Manager&release=1.9.0.0&platform=Linux&function=fixId&fixids=1.9.0.0-IBMIM-LINUX-X86_64-20190715_0328&useReleaseAsTarget=true&includeRequisites=1&includeSupersedes=0&downloadMethod=http)
 - Install [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest)
 - Install [PowerShell Core](https://docs.microsoft.com/en-us/powershell/scripting/install/installing-powershell-core-on-linux?view=powershell-6)
 - Install Maven

 ## Steps of deployment
 1. Checkout [azure-javaee-iaas](https://github.com/Azure/azure-javaee-iaas)
    - change to directory hosting the repo project & run `mvn clean install`
 2. Checkout [azure-quickstart-templates](https://github.com/Azure/azure-quickstart-templates) under the specified parent directory
 3. Checkout this repo under the same parent directory and change to directory hosting the repo project
 4. Change to sub-directory `add-nodes`
 5. Build the project by replacing all placeholder `${<place_holder>}` with valid values
    ```
    mvn -Dgit.repo=<repo_user> -Dgit.tag=<repo_tag> -DnumberOfNodes=<numberOfNodes> -DmanagedVMPrefix=<managedVMPrefix> -DdnsLabelPrefix=<dnsLabelPrefix> -DibmUserId=<ibmUserId> -DibmUserPwd=<ibmUserPwd> -DvmAdminId=<vmAdminId> -DvmAdminPwd=<vmAdminPwd> -DadminUser=<adminUser> -DadminPwd=<adminPwd> -DclusterName=<clusterName> -DnodeGroupName=<nodeGroupName> -DcoreGroupName=<coreGroupName> -DdmgrHostName=<dmgrHostName> -DdmgrPort=<dmgrPort> -DvNetName=<vNetName> -DsubnetName=<subnetName> -Dtest.args="-Test All" -Ptemplate-validation-tests clean install
    ```
 6. Change to `./target/arm` directory
 7. Using `deploy.azcli` to deploy
    ```
    ./deploy.azcli -n <deploymentName> -f <installKitFile> -i <subscriptionId> -g <resourceGroupName> -l <resourceGroupLocation>
    ```

## After deployment
- If you check the resource group in [azure portal](https://portal.azure.com/), you will see new VMs and related resources created
- Open VM resource blade of deployment manager and copy its DNS name, then open IBM WebSphere Integrated Solutions Console for further administration by browsing https://<dns_name>:9043/ibm/console
- The deployment manager and node agent running in the cluster will be automatically started whenever the virtual machine is rebooted. In case you want to mannually stop/start/restart the process, using the following commands:
  ```
  /opt/IBM/WebSphere/ND/V9/bin/stopServer.sh <serverName>   # stop server
  /opt/IBM/WebSphere/ND/V9/bin/startServer.sh <serverName>  # start server
  ```
