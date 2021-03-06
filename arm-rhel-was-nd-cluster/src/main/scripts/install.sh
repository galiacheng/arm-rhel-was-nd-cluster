#!/bin/sh

create_dmgr_profile() {
    profileName=$1
    nodeName=$2
    cellName=$3
    adminUserName=$4
    adminPassword=$5

    /opt/IBM/WebSphere/ND/V9/bin/manageprofiles.sh -create -profileName ${profileName} \
        -templatePath /opt/IBM/WebSphere/ND/V9/profileTemplates/management -serverType DEPLOYMENT_MANAGER \
        -nodeName ${nodeName} -cellName ${cellName} -enableAdminSecurity true -adminUserName ${adminUserName} -adminPassword ${adminPassword}
}

add_admin_credentials_to_soap_client_props() {
    profileName=$1
    adminUserName=$2
    adminPassword=$3
    soapClientProps=/opt/IBM/WebSphere/ND/V9/profiles/${profileName}/properties/soap.client.props

    # Add admin credentials
    sed -i "s/com.ibm.SOAP.securityEnabled=false/com.ibm.SOAP.securityEnabled=true/g" "$soapClientProps"
    sed -i "s/com.ibm.SOAP.loginUserid=/com.ibm.SOAP.loginUserid=${adminUserName}/g" "$soapClientProps"
    sed -i "s/com.ibm.SOAP.loginPassword=/com.ibm.SOAP.loginPassword=${adminPassword}/g" "$soapClientProps"

    # Encrypt com.ibm.SOAP.loginPassword
    /opt/IBM/WebSphere/ND/V9/profiles/${profileName}/bin/PropFilePasswordEncoder.sh "$soapClientProps" com.ibm.SOAP.loginPassword
}

create_systemd_service() {
    srvName=$1
    srvDescription=$2
    profileName=$3
    serverName=$4
    srvPath=/etc/systemd/system/${srvName}.service

    # Add systemd unit file
    echo "[Unit]" > "$srvPath"
    echo "Description=${srvDescription}" >> "$srvPath"
    echo "[Service]" >> "$srvPath"
    echo "Type=forking" >> "$srvPath"
    echo "ExecStart=/opt/IBM/WebSphere/ND/V9/profiles/${profileName}/bin/startServer.sh ${serverName}" >> "$srvPath"
    echo "ExecStop=/opt/IBM/WebSphere/ND/V9/profiles/${profileName}/bin/stopServer.sh ${serverName}" >> "$srvPath"
    echo "PIDFile=/opt/IBM/WebSphere/ND/V9/profiles/${profileName}/logs/${serverName}/${serverName}.pid" >> "$srvPath"
    echo "SuccessExitStatus=143 0" >> "$srvPath"
    echo "[Install]" >> "$srvPath"
    echo "WantedBy=default.target" >> "$srvPath"

    # Enable service
    systemctl daemon-reload
    systemctl enable "$srvName"
}

create_cluster() {
    profileName=$1
    dmgrNode=$2
    cellName=$3
    clusterName=$4
    members=$5
    dynamic=$6

    nodes=( $(/opt/IBM/WebSphere/ND/V9/profiles/${profileName}/bin/wsadmin.sh -lang jython -c "AdminConfig.list('Node')" \
        | grep -Po "(?<=\/nodes\/)[^|]*(?=|.*)" | grep -v $dmgrNode | sed 's/^/"/;s/$/"/') )
    while [ ${#nodes[@]} -ne $members ]
    do
        sleep 5
        echo "adding more nodes..."
        nodes=( $(/opt/IBM/WebSphere/ND/V9/profiles/${profileName}/bin/wsadmin.sh -lang jython -c "AdminConfig.list('Node')" \
            | grep -Po "(?<=\/nodes\/)[^|]*(?=|.*)" | grep -v $dmgrNode | sed 's/^/"/;s/$/"/') )
    done
    sleep 60

    if [ "$dynamic" = True ]; then
        echo "all nodes are managed, creating dynamic cluster..."
        cp create-dcluster.py create-dcluster.py.bak
        sed -i "s/\${CLUSTER_NAME}/${clusterName}/g" create-dcluster.py
        sed -i "s/\${NODE_GROUP_NAME}/DefaultNodeGroup/g" create-dcluster.py
        sed -i "s/\${CORE_GROUP_NAME}/DefaultCoreGroup/g" create-dcluster.py
        /opt/IBM/WebSphere/ND/V9/profiles/${profileName}/bin/wsadmin.sh -lang jython -f create-dcluster.py
    else
        echo "all nodes are managed, creating cluster..."
        nodes_string=$( IFS=,; echo "${nodes[*]}" )
        cp create-cluster.py create-cluster.py.bak
        sed -i "s/\${CELL_NAME}/${cellName}/g" create-cluster.py
        sed -i "s/\${CLUSTER_NAME}/${clusterName}/g" create-cluster.py
        sed -i "s/\${NODES_STRING}/${nodes_string}/g" create-cluster.py
        /opt/IBM/WebSphere/ND/V9/profiles/${profileName}/bin/wsadmin.sh -lang jython -f create-cluster.py
    fi

    echo "cluster \"${clusterName}\" is successfully created!"
}

create_data_source() {
    profileName=$1
    clusterName=$2
    db2ServerName=$3
    db2ServerPortNumber=$4
    db2DBName=$5
    db2DBUserName=$6
    db2DBUserPwd=$7
    db2DSJndiName=${8:-jdbc/Sample}
    jdbcDriverPath=/opt/IBM/WebSphere/ND/V9/db2/java

    if [ -z "$db2ServerName" ] || [ -z "$db2ServerPortNumber" ] || [ -z "$db2DBName" ] || [ -z "$db2DBUserName" ] || [ -z "$db2DBUserPwd" ]; then
        echo "quit due to DB2 connectoin info is not provided"
        return 0
    fi

    # Get jython file template & replace placeholder strings with user-input parameters
    cp create-ds.py create-ds.py.bak
    sed -i "s/\${CLUSTER_NAME}/${clusterName}/g" create-ds.py
    sed -i "s#\${DB2UNIVERSAL_JDBC_DRIVER_PATH}#${jdbcDriverPath}#g" create-ds.py
    sed -i "s/\${DB2_DATABASE_USER_NAME}/${db2DBUserName}/g" create-ds.py
    sed -i "s/\${DB2_DATABASE_USER_PASSWORD}/${db2DBUserPwd}/g" create-ds.py
    sed -i "s/\${DB2_DATABASE_NAME}/${db2DBName}/g" create-ds.py
    sed -i "s#\${DB2_DATASOURCE_JNDI_NAME}#${db2DSJndiName}#g" create-ds.py
    sed -i "s/\${DB2_SERVER_NAME}/${db2ServerName}/g" create-ds.py
    sed -i "s/\${PORT_NUMBER}/${db2ServerPortNumber}/g" create-ds.py

    # Create JDBC provider and data source using jython file
    /opt/IBM/WebSphere/ND/V9/profiles/${profileName}/bin/wsadmin.sh -lang jython -f create-ds.py
    sleep 60
    # Restart active nodes which will restart all servers running on the nodes
    /opt/IBM/WebSphere/ND/V9/profiles/${profileName}/bin/wsadmin.sh -lang jython -c "AdminNodeManagement.restartActiveNodes()"
    echo "DB2 JDBC provider and data source are successfully created!"
}

enable_hpel() {
    wasProfilePath=/opt/IBM/WebSphere/ND/V9/profiles/$1 #WAS ND profile path
    nodeName=$2 #Node name
    wasServerName=$3 #WAS ND server name
    outLogPath=$4 #Log output path
    logViewerSvcName=$5 #Name of log viewer service

    # Enable HPEL service
    cp enable-hpel.template enable-hpel-${wasServerName}.py
    sed -i "s/\${WAS_SERVER_NAME}/${wasServerName}/g" enable-hpel-${wasServerName}.py
    sed -i "s/\${NODE_NAME}/${nodeName}/g" enable-hpel-${wasServerName}.py
    "$wasProfilePath"/bin/wsadmin.sh -lang jython -f enable-hpel-${wasServerName}.py

# Add systemd unit file for log viewer service
    cat <<EOF > /etc/systemd/system/${logViewerSvcName}.service
[Unit]
Description=IBM WebSphere Application Log Viewer
[Service]
Type=simple
ExecStart=${wasProfilePath}/bin/logViewer.sh -repositoryDir ${wasProfilePath}/logs/${wasServerName} -outLog ${outLogPath} -resumable -resume -format json -monitor
[Install]
WantedBy=default.target
EOF

    # Enable log viewer service
    systemctl daemon-reload
    systemctl enable "$logViewerSvcName"
}

setup_filebeat() {
    # Parameters
    outLogPaths=$1 #Log output paths
    IFS=',' read -r -a array <<< "$outLogPaths"
    logStashServerName=$2 #Host name/IP address of LogStash Server
    logStashServerPortNumber=$3 #Port number of LogStash Server

    # Install Filebeat
    rpm --import https://artifacts.elastic.co/GPG-KEY-elasticsearch
    cat <<EOF > /etc/yum.repos.d/elastic.repo
[elasticsearch-7.x]
name=Elasticsearch repository for 7.x packages
baseurl=https://artifacts.elastic.co/packages/7.x/yum
gpgcheck=1
gpgkey=https://artifacts.elastic.co/GPG-KEY-elasticsearch
enabled=1
autorefresh=1
type=rpm-md
EOF
    yum install filebeat -y

    # Configure Filebeat
    mv /etc/filebeat/filebeat.yml /etc/filebeat/filebeat.yml.bak
    fbConfigFilePath=/etc/filebeat/filebeat.yml
    echo "filebeat.inputs:" > "$fbConfigFilePath"
    echo "- type: log" >> "$fbConfigFilePath"
    echo "  paths:" >> "$fbConfigFilePath"
    for outLogPath in "${array[@]}"
    do
        echo "    - ${outLogPath}" >> "$fbConfigFilePath"
    done
    echo "processors:" >> "$fbConfigFilePath"
    echo "- add_cloud_metadata:" >> "$fbConfigFilePath"
    echo "output.logstash:" >> "$fbConfigFilePath"
    echo "  hosts: [\"${logStashServerName}:${logStashServerPortNumber}\"]" >> "$fbConfigFilePath"

    # Enable & start filebeat
    systemctl daemon-reload
    systemctl enable filebeat
    systemctl start filebeat
}

create_custom_profile() {
    profileName=$1
    dmgrHostName=$2
    dmgrPort=$3
    dmgrAdminUserName=$4
    dmgrAdminPassword=$5
    
    curl $dmgrHostName:$dmgrPort >/dev/null 2>&1
    while [ $? -ne 0 ]
    do
        sleep 5
        echo "dmgr is not ready"
        curl $dmgrHostName:$dmgrPort >/dev/null 2>&1
    done
    sleep 60
    echo "dmgr is ready to add nodes"

    output=$(/opt/IBM/WebSphere/ND/V9/bin/manageprofiles.sh -create -profileName $profileName \
        -profilePath /opt/IBM/WebSphere/ND/V9/profiles/$profileName -templatePath /opt/IBM/WebSphere/ND/V9/profileTemplates/managed \
        -dmgrHost $dmgrHostName -dmgrPort $dmgrPort -dmgrAdminUserName $dmgrAdminUserName -dmgrAdminPassword $dmgrAdminPassword 2>&1)
    while echo $output | grep -qv "SUCCESS"
    do
        sleep 10
        echo "adding node failed, retry it later..."
        rm -rf /opt/IBM/WebSphere/ND/V9/profiles/$profileName
        output=$(/opt/IBM/WebSphere/ND/V9/bin/manageprofiles.sh -create -profileName $profileName \
            -profilePath /opt/IBM/WebSphere/ND/V9/profiles/$profileName -templatePath /opt/IBM/WebSphere/ND/V9/profileTemplates/managed \
            -dmgrHost $dmgrHostName -dmgrPort $dmgrPort -dmgrAdminUserName $dmgrAdminUserName -dmgrAdminPassword $dmgrAdminPassword 2>&1)
    done
    echo $output
}

copy_db2_drivers() {
    wasRootPath=/opt/IBM/WebSphere/ND/V9
    jdbcDriverPath="$wasRootPath"/db2/java

    mkdir -p "$jdbcDriverPath"
    find "$wasRootPath" -name "db2jcc*.jar" | xargs -I{} cp {} "$jdbcDriverPath"
}

elk_logging_ready_check() {
    cellName=$1
    profileName=$2

    output=$(/opt/IBM/WebSphere/ND/V9/profiles/${profileName}/bin/wsadmin.sh -lang jython -f get_custom_property.py ${cellName} enableClusterELKLogging 2>&1)
    while echo $output | grep -qv "enableClusterELKLogging:true"
    do
        sleep 10
        echo "Setup cluster ELK logging is not ready, retry it later..."
        output=$(/opt/IBM/WebSphere/ND/V9/profiles/${profileName}/bin/wsadmin.sh -lang jython -f get_custom_property.py ${cellName} enableClusterELKLogging 2>&1)
    done
    echo "Ready to setup cluster ELK logging now"
}

cluster_member_running_state() {
    profileName=$1
    nodeName=$2
    serverName=$3

    output=$(/opt/IBM/WebSphere/ND/V9/profiles/${profileName}/bin/wsadmin.sh -lang jython -c "mbean=AdminControl.queryNames('type=Server,node=${nodeName},name=${serverName},*');print 'STARTED' if mbean else 'RESTARTING'" 2>&1)
    if echo $output | grep -q "STARTED"; then
	    return 0
    else
        return 1
    fi
}

while getopts "l:u:p:m:c:f:h:r:x:n:t:d:i:s:j:g:o:" opt; do
    case $opt in
        l)
            imKitLocation=$OPTARG #SAS URI of the IBM Installation Manager install kit in Azure Storage
        ;;
        u)
            userName=$OPTARG #IBM user id for downloading artifacts from IBM web site
        ;;
        p)
            password=$OPTARG #password of IBM user id for downloading artifacts from IBM web site
        ;;
        m)
            adminUserName=$OPTARG #User id for admimistrating WebSphere Admin Console
        ;;
        c)
            adminPassword=$OPTARG #Password for administrating WebSphere Admin Console
        ;;
        f)
            dmgr=$OPTARG #Flag indicating whether to install deployment manager
        ;;
        h)
            dmgrHostName=$OPTARG #Host name of deployment manager server
        ;;
        r)
            members=$OPTARG #Number of cluster members
        ;;
        x)
            dynamic=$OPTARG #Flag indicating whether to create a dynamic cluster or not
        ;;
        n)
            db2ServerName=$OPTARG #Host name/IP address of IBM DB2 Server
        ;;
        t)
            db2ServerPortNumber=$OPTARG #Server port number of IBM DB2 Server
        ;;
        d)
            db2DBName=$OPTARG #Database name of IBM DB2 Server
        ;;
        i)
            db2DBUserName=$OPTARG #Database user name of IBM DB2 Server
        ;;
        s)
            db2DBUserPwd=$OPTARG #Database user password of IBM DB2 Server
        ;;
        j)
            db2DSJndiName=$OPTARG #Datasource JNDI name
        ;;
        g)
            logStashServerName=$OPTARG #Host name/IP address of LogStash Server
        ;;
        o)
            logStashServerPortNumber=$OPTARG #Port number of LogStash Server
        ;;
    esac
done

# Variables
imKitName=agent.installer.linux.gtk.x86_64_1.9.0.20190715_0328.zip
repositoryUrl=http://www.ibm.com/software/repositorymanager/com.ibm.websphere.ND.v90
wasNDTraditional=com.ibm.websphere.ND.v90_9.0.5001.20190828_0616
ibmJavaSDK=com.ibm.java.jdk.v8_8.0.5040.20190808_0919

# Turn off firewall
systemctl stop firewalld
systemctl disable firewalld

# Create installation directories
mkdir -p /opt/IBM/InstallationManager/V1.9 && mkdir -p /opt/IBM/WebSphere/ND/V9 && mkdir -p /opt/IBM/IMShared

# Install IBM Installation Manager
wget -O "$imKitName" "$imKitLocation" -q
mkdir im_installer
unzip -q "$imKitName" -d im_installer
./im_installer/userinstc -log log_file -acceptLicense -installationDirectory /opt/IBM/InstallationManager/V1.9

# Install IBM WebSphere Application Server Network Deployment V9 using IBM Instalation Manager
/opt/IBM/InstallationManager/V1.9/eclipse/tools/imutilsc saveCredential -secureStorageFile storage_file \
    -userName "$userName" -userPassword "$password" -url "$repositoryUrl"
/opt/IBM/InstallationManager/V1.9/eclipse/tools/imcl install "$wasNDTraditional" "$ibmJavaSDK" -repositories "$repositoryUrl" \
    -installationDirectory /opt/IBM/WebSphere/ND/V9/ -sharedResourcesDirectory /opt/IBM/IMShared/ \
    -secureStorageFile storage_file -acceptLicense -showProgress

# Create cluster by creating deployment manager, node agent & add nodes to be managed
if [ "$dmgr" = True ]; then
    create_dmgr_profile Dmgr001 Dmgr001Node Dmgr001NodeCell "$adminUserName" "$adminPassword"
    add_admin_credentials_to_soap_client_props Dmgr001 "$adminUserName" "$adminPassword"
    create_systemd_service was_dmgr "IBM WebSphere Application Server ND Deployment Manager" Dmgr001 dmgr
    /opt/IBM/WebSphere/ND/V9/profiles/Dmgr001/bin/startServer.sh dmgr
    create_cluster Dmgr001 Dmgr001Node Dmgr001NodeCell MyCluster $members $dynamic
    create_data_source Dmgr001 MyCluster "$db2ServerName" "$db2ServerPortNumber" "$db2DBName" "$db2DBUserName" "$db2DBUserPwd" "$db2DSJndiName"
    if [ ! -z "$logStashServerName" ] && [ ! -z "$logStashServerPortNumber" ]; then
        enable_hpel Dmgr001 Dmgr001Node dmgr /opt/IBM/WebSphere/ND/V9/profiles/Dmgr001/logs/dmgr/hpelOutput.log was_dmgr_logviewer
        /opt/IBM/WebSphere/ND/V9/profiles/Dmgr001/bin/stopServer.sh dmgr
        /opt/IBM/WebSphere/ND/V9/profiles/Dmgr001/bin/startServer.sh dmgr
        systemctl start was_dmgr_logviewer
        setup_filebeat "/opt/IBM/WebSphere/ND/V9/profiles/Dmgr001/logs/dmgr/hpelOutput*.log" "$logStashServerName" "$logStashServerPortNumber"
        /opt/IBM/WebSphere/ND/V9/profiles/Dmgr001/bin/wsadmin.sh -lang jython -f set_custom_property.py Dmgr001NodeCell logStashServerName "$logStashServerName"
        /opt/IBM/WebSphere/ND/V9/profiles/Dmgr001/bin/wsadmin.sh -lang jython -f set_custom_property.py Dmgr001NodeCell logStashServerPortNumber "$logStashServerPortNumber"
        /opt/IBM/WebSphere/ND/V9/profiles/Dmgr001/bin/wsadmin.sh -lang jython -f set_custom_property.py Dmgr001NodeCell enableClusterELKLogging true
    fi
else
    create_custom_profile Custom $dmgrHostName 8879 "$adminUserName" "$adminPassword"
    add_admin_credentials_to_soap_client_props Custom "$adminUserName" "$adminPassword"
    create_systemd_service was_nodeagent "IBM WebSphere Application Server ND Node Agent" Custom nodeagent
    copy_db2_drivers
    if [ ! -z "$logStashServerName" ] && [ ! -z "$logStashServerPortNumber" ]; then
        elk_logging_ready_check Dmgr001NodeCell Custom
        
        cluster_member_running_state Custom $(hostname)Node01 MyCluster_$(hostname)Node01
        running=$?
        if [ $running -ne 0 ]; then
	        /opt/IBM/WebSphere/ND/V9/profiles/Custom/bin/startServer.sh MyCluster_$(hostname)Node01
        fi

        enable_hpel Custom $(hostname)Node01 nodeagent /opt/IBM/WebSphere/ND/V9/profiles/Custom/logs/nodeagent/hpelOutput.log was_na_logviewer
        enable_hpel Custom $(hostname)Node01 MyCluster_$(hostname)Node01 /opt/IBM/WebSphere/ND/V9/profiles/Custom/logs/MyCluster_$(hostname)Node01/hpelOutput.log was_cm_logviewer
        
        /opt/IBM/WebSphere/ND/V9/profiles/Custom/bin/wsadmin.sh -lang jython -c "na=AdminControl.queryNames('type=NodeAgent,node=$(hostname)Node01,*');AdminControl.invoke(na,'restart','true true')"
        cluster_member_running_state Custom $(hostname)Node01 MyCluster_$(hostname)Node01
        while [ $? -ne 0 ]
        do
            echo "Restarting node agent & cluster member..."
            cluster_member_running_state Custom $(hostname)Node01 MyCluster_$(hostname)Node01
        done
        echo "Node agent & cluster member are both restarted now"

        systemctl start was_na_logviewer
        systemctl start was_cm_logviewer

        if [ $running -ne 0 ]; then
            /opt/IBM/WebSphere/ND/V9/profiles/Custom/bin/stopServer.sh MyCluster_$(hostname)Node01
        fi

        setup_filebeat "/opt/IBM/WebSphere/ND/V9/profiles/Custom/logs/nodeagent/hpelOutput*.log,/opt/IBM/WebSphere/ND/V9/profiles/Custom/logs/MyCluster_$(hostname)Node01/hpelOutput*.log" "$logStashServerName" "$logStashServerPortNumber"
    fi
fi
