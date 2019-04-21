# create the operational user
talenduser:
  group.present:
    - name: talenduser
  user.present:
    - gid_from_name: True
    - groups:
      - talenduser
    - require:
      - group: talenduser

##### JAVA Install 
removeoldJava:
  pkg.removed:
    - pkgs: 
      - java-1.7.0-openjdk-devel
      - java-1.7.0-openjdk
    - require:
      - cmd: javaInstall

javaInstall: # I was told by the contractor assisting this installation, that only the Oracle JDK was supported by Talend
  file.directory:
    - name: /usr/java/jvm
    - makedirs: True
    - user: root
    - group: root
  cmd.run:  # I tend to store install binaries in S3 buckets, in case the download location is archived, or if authentication is required for the download
    - name: aws s3 cp s3://your-bucket/jdk-8u171-linux-x64.tar.gz /tmp/jdk-8u171-linux-x64.tar.gz && tar -xzf /tmp/jdk-8u171-linux-x64.tar.gz
    - cwd: /usr/java/jvm/
    - require: 
      - file: javaInstall
    - unless:
      - ls /usr/java/jvm/jdk1.8.0_171

/etc/environment:
  file.managed:
    - source: salt://environment
  cmd.run: # there may be a cleaner way to install a JDK, and set it in the PATH, but this works
    - name: source /etc/environment
    - require:
      - file: /etc/environment
      - cmd: javaInstall 
##### End Java Install

##### MQ Install
downloadActiveMQ:
  cmd.run:
    - name: aws s3 cp s3://your-bucket/apache-activemq-5.15.4-bin.tar.gz /tmp/apache-activemq-5.15.4-bin.tar.gz && tar -xzf /tmp/apache-activemq-5.15.4-bin.tar.gz 
    - cwd: /opt
    - require:
      - cmd: /etc/environment
  file.directory:
    - name: /opt/apache-activemq-5.15.4/
    - user: talenduser
    - group: talenduser
    - recurse:
      - user
      - group
    - require:
      - cmd: downloadActiveMQ

changebrokername:
  file.replace:
    - name: /opt/apache-activemq-5.15.4/conf/activemq.xml
    - pattern: <broker xmlns="http://activemq.apache.org/schema/core" brokerName="localhost" dataDirectory="${activemq.data}">
    - repl: <broker xmlns="http://activemq.apache.org/schema/core" advisorySupport="false" brokerName="localhost" dataDirectory="${activemq.data}">
    - require:
      - cmd: downloadActiveMQ

copyenv:
  file.copy:
    - name: /etc/default/activemq
    - source: /opt/apache-activemq-5.15.4/bin/env
    - mode: 644
    - user: talenduser
    - group: talenduser
    - require:
      - file: changebrokername

replaceline:
  file.replace:
    - name: /etc/default/activemq
    - pattern: ACTIVEMQ_USER=""
    - repl: ACTIVEMQ_USER="talenduser"
    - require:
      - file: copyenv
addJavaHome:
  file.replace:
    - name: /etc/default/activemq
    - pattern: \#JAVA_HOME=""
    - repl: JAVA_HOME="/usr/java/jvm/jdk1.8.0_171"
    - require: 
      - file: replaceline
      
createMQService:
  file.symlink:
    - name: /etc/init.d/activemq
    - target: /opt/apache-activemq-5.15.4/bin/activemq
    - mode: 755
    - force: True
  service.running:
    - name: activemq
    - enable: True
    - reload: True
    - init_delay: 60
    - watch:
      - file: /etc/default/activemq
    - require:
      - file: createMQService
      - file: addJavaHome

installremove:
  file.absent:
    - name: /tmp/apache-activemq-5.15.4-bin.tar.gz
    - require:
      - service: createMQService
##### End MQ Install

##### Karaf Install
esbinstall:
  file.directory:
    - name: /opt/containers/_containers
    - makedirs: True
    - user: talenduser
    - group: talenduser
    - recurse:
      - user
      - group
    - require: 
      - user: talenduser
      - group: talenduser
  cmd.run:
    - name: aws s3 cp s3://your-bucket/Talend-Runtime-V6.5.1-20180110150853.zip /tmp/Talend-Runtime-V6.5.1-20180110150853.zip && unzip /tmp/Talend-Runtime-V6.5.1-20180110150853.zip -d /opt/ && mv -v /opt/Talend-Runtime-V6.5.1/* /opt/containers/_containers
    - cwd: /opt
    - unless: ls /opt/containers/_containers/LICENSE.txt
    - require:
      - user: talenduser
      - group: talenduser
      - file: esbinstall
    
wrapperinstall: # These wrappers are provided by Talend
  cmd.run:
    - name: aws s3 cp s3://your-bucket/esb-wrapperfiles.zip /tmp/esb-wrapperfiles.zip && unzip /tmp/esb-wrapperfiles.zip -d /opt/containers/_containers/
    - cwd: /opt/containers/_containers/
    - unless: ls /opt/containers/_containers/bin/internal-API-wrapper
  file.managed:
    - name: /opt/containers/_containers/bin/internal-API-wrapper
    - mode: 755
    - require:
      - cmd: esbinstall

/opt/containers/_containers/etc/org.ops4j.pax.url.mvn.cfg:
  file.managed: # this file is configured to show the location of Binary repositories
    - source: salt://org.ops4j.pax.url.mvn.cfg
    - user: talenduser
    - group: talenduser
    - template: jinja
    - require:
      - cmd: esbinstall

{%- if salt['file.directory_exists' ]('/opt/containers/internal-API') == false %}
# create first karafe, additional karafe's should be in subfolders of /opt/containers
/opt/containers/internal-API:
  file.directory:
    - makedirs: True
    - user: talenduser
    - group: talenduser
    - recurse:
      - user
      - group
  cmd.run:
    - name: cp -r /opt/containers/_containers/* /opt/containers/internal-API/
    - require:
      - cmd: wrapperinstall

confinstall:
  file.managed:
    - name: /opt/containers/internal-API/etc/internal-API-wrapper.conf
    - source: salt://wrapper.conf
    - makedirs: True
    - unless: ls /opt/containers/internal-API/etc/internal-API-wrapper.conf
    - mode: 755
    - user: talenduser
    - group: talenduser
    - template: jinja
    - defaults:
        CONTAINER: "internal-API"
        JVMMEM: 2048
    - require:
        - cmd: /opt/containers/internal-API

serviceinstall:
  file.managed: 
    - name: /opt/containers/internal-API/bin/internal-API
    - source: salt://esb-service.conf
    - makedirs: True
    - mode: 755
    - user: talenduser
    - group: talenduser
    - unless: ls /opt/containers/internal-API/bin/internal-API
    - template: jinja
    - defaults:
        CONTAINER: "internal-API"
    - require:
      - file: confinstall

internal-API-enable:
  file.copy:
    - name: /etc/init.d/internal-API
    - source: /opt/containers/internal-API/bin/internal-API
  service.running:
    - name: internal-API
    - enable: True
    - init_delay: 60
    - watch:
      - file: confinstall
    - require:
      - file: containerrename
      
containerrename:
  file.replace:
    - name: /opt/containers/internal-API/etc/system.properties
    - pattern: karaf.name=trun
    - repl: karaf.name=internal-API
    - require:
      - file: serviceinstall
{%- endif %}

# install additional karaf's
# set variables for each of their original port numbers
# these port numbers are used for the first karaf, so must be incremented at the beginning of the loop.
{% set rmiRegistryPort = 1099 %}       # my original salt had a loop for building multiple identical karaf's
{% set rmiServerPort = 44444 %}        # I did have to remove the loop, but want to keep the port numbers
{% set httpPort = 8040 %}              # and increments in place, for reference
{% set httpsPort = 9001 %}
{% set sshPortNumber = 8101 %}
{% set jobserverCommandPort = 8000 %}
{% set jobserverFilePort = 8001 %}
{% set jobserverMonitorPort = 8888 %}

# begin loop
# additional karafe's must be added to the end of the comma seperated list.  Existing karafe's must not be switched in order
# add a log entry in the splunk config, modelled after the other container logs
# increment all ports
{% set rmiRegistryPort = 1 + rmiRegistryPort %}
{% set rmiServerPort = 1 + rmiServerPort %}
{% set httpPort = 1 + httpPort %}
{% set httpsPort = 1 + httpsPort %}
{% set sshPortNumber = 1 + sshPortNumber %}
{% set jobserverCommandPort = 10 + jobserverCommandPort %}
{% set jobserverFilePort = 10 + jobserverFilePort %}
{% set jobserverMonitorPort = 10 + jobserverMonitorPort %}

createKaraf-internal-Services:
  file.directory:
    - name: /opt/containers/internal-Services
    - makedirs: True
    - user: talenduser
    - group: talenduser
    - recurse:
      - user
      - group
    - unless: ls /opt/containers/internal-Services
  cmd.run:
    - name: cp -r /opt/containers/_containers/* /opt/containers/internal-Services/
    - require:
      - cmd: esbinstall
      - user: talenduser
      - group: talenduser

# the next two states add configuration changes to allow the karaf to communicate with a database to help with failover with the TAC
featureRepositoriesAdd:
  file.replace: 
    - name: /opt/containers/internal-Services/etc/org.apache.karaf.features.cfg
    - pattern: mvn:org.talend.esb.provisioning/provisioning-features-agent/6.5.1/xml
    - repl: mvn:org.talend.esb.provisioning/provisioning-features-agent/6.5.1/xml, mvn:org.jasypt/jasypt/1.9.1, mvn:org.apache.servicemix.bundles/org.apache.servicemix.bundles.commons-dbcp/1.4_3, mvn:org.jasypt/jasypt/1.9.1
    - require:
      - cmd: createKarafinternal-Services

featureBootAdd:
  file.replace:
    - name: /opt/containers/internal-Services/etc/org.apache.karaf.features.cfg
    - pattern: tesb-swagger
    - repl: tesb-swagger, jdbc, pax-jdbc-mysql, pax-jdbc-postgresql, camel-jasypt, jndi
    - require:
      - file: featureRepositoriesAdd

{% if 'dev' in grains['host'] %}
{% set envid = 'dev' %}
{% elif 'qa' in grains['host'] %}
{% set envid = 'qa' %}
{% elif 'stage' in grains['host'] %}
{% set envid = 'stage' %}
{% elif 'prod' in grains['host'] %}
{% set envid = 'prod' %}
{% endif %}
dataSourceProperty:
  file.managed:
    - name: /opt/containers/internal-Services/etc/datasource.properties
    - source: salt://datasource.properties
    - user: talenduser
    - group: talenduser
    - mode: 644
    - template: jinja
    - defaults:
        ENV_URL: talenddb-esb.{{ envid }}
    - require:
      - file: featureBootAdd

getDataSourceJar:
  cmd.run:
    - name: aws s3 cp  s3://your-bucket/datasource.jar /opt/containers/internal-Services/deploy/datasource.jar
    - require:
      - file: dataSourceProperty

createWrapperinternal-Services:
  file.rename:
    - name: /opt/containers/internal-Services/bin/internal-Services-wrapper
    - source: /opt/containers/internal-Services/bin/internal-API-wrapper
    - unless: ls /opt/containers/internal-Services/bin/internal-Services-wrapper 
    - force: True
    - keep_source: False
    - require:
      - cmd: getDataSourceJar
    
createWrapperConfinternal-Services:
  file.managed:
    - name: /opt/containers/internal-Services/etc/internal-Services-wrapper.conf
    - source: salt://wrapper.conf
    - mode: 755
    - user: talenduser
    - group: talenduser
    - template: jinja
    - defaults:
        CONTAINER: "internal-Services"
        JVMMEM: 2048
    - require:
        - file: createWrapperinternal-Services
# the next few states update the ports from their defaults. 
rmiRegistryPortSetinternal-Services:
  file.replace:
    - name: /opt/containers/internal-Services/etc/org.apache.karaf.management.cfg
    - pattern: rmiRegistryPort = 1099
    - repl: rmiRegistryPort = {{ rmiRegistryPort }}
    - require: 
      - file: createWrapperConfinternal-Services

rmiServerPortSetinternal-Services:
  file.replace:
    - name: /opt/containers/internal-Services/etc/org.apache.karaf.management.cfg
    - pattern: rmiServerPort = 44444
    - repl: rmiServerPort = {{ rmiServerPort }}
    - require: 
      - file: rmiRegistryPortSetinternal-Services

httpPortSetinternal-Services:
  file.replace:
    - name: /opt/containers/internal-Services/etc/org.ops4j.pax.web.cfg
    - pattern: org.osgi.service.http.port=8040
    - repl: org.osgi.service.http.port={{ httpPort }}
    - require: 
      - file: rmiServerPortSetinternal-Services

httpPortSetinternal-ServicesESBLocator:
  file.replace:
    - name: /opt/containers/internal-Services/etc/org.talend.esb.locator.cfg
    - pattern: endpoint.http.prefix=http://localhost:8040
    - repl: endpoint.http.prefix=http://localhost:{{ httpPort }}
    - require: 
      - file: httpPortSetinternal-Services

httpsPortSetinternal-Services:
  file.replace:
    - name: /opt/containers/internal-Services/etc/org.ops4j.pax.web.cfg
    - pattern: org.osgi.service.http.port.secure=9001
    - repl: org.osgi.service.http.port.secure={{ httpsPort }}
    - require: 
      - file: httpPortSetinternal-ServicesESBLocator

httpsPortSetinternal-ServicesESBLocator:
  file.replace:
    - name: /opt/containers/internal-Services/etc/org.talend.esb.locator.cfg
    - pattern: endpoint.https.prefix=https://localhost:9001
    - repl: endpoint.https.prefix=https://localhost:{{ httpsPort }}
    - require: 
      - file: httpsPortSetinternal-Services

sshPortSetinternal-Services:
  file.line:
    - name: /opt/containers/internal-Services/etc/org.apache.karaf.shell.cfg
    - match: sshPort = 8101
    - content: sshPort = {{ sshPortNumber }}
    - mode: replace
    - require: 
      - file: httpsPortSetinternal-ServicesESBLocator

jobserverCommandPortSetinternal-Services:
  file.replace:
    - name: /opt/containers/internal-Services/etc/org.talend.remote.jobserver.server.cfg
    - pattern: org.talend.remote.jobserver.server.TalendJobServer.COMMAND_SERVER_PORT=8000
    - repl: org.talend.remote.jobserver.server.TalendJobServer.COMMAND_SERVER_PORT={{ jobserverCommandPort }}
    - require: 
      - file: sshPortSetinternal-Services

jobserverFilePortSetinternal-Services:
  file.replace:
    - name: /opt/containers/internal-Services/etc/org.talend.remote.jobserver.server.cfg
    - pattern: org.talend.remote.jobserver.server.TalendJobServer.FILE_SERVER_PORT=8001
    - repl: org.talend.remote.jobserver.server.TalendJobServer.FILE_SERVER_PORT={{ jobserverFilePort }}
    - require: 
      - file: jobserverCommandPortSetinternal-Services

jobserverMonitorPortSetinternal-Services:
  file.replace:
    - name: /opt/containers/internal-Services/etc/org.talend.remote.jobserver.server.cfg
    - pattern: org.talend.remote.jobserver.server.TalendJobServer.MONITORING_PORT=8888
    - repl: org.talend.remote.jobserver.server.TalendJobServer.MONITORING_PORT={{ jobserverMonitorPort }}
    - require: 
      - file: jobserverFilePortSetinternal-Services

createinternal-ServicesService:
  file.managed: 
    - name: /opt/containers/internal-Services/bin/internal-Services
    - source: salt://common/files/esb/esb-service.conf
    - makedirs: True
    - mode: 755
    - user: talenduser
    - group: talenduser
    - template: jinja
    - defaults:
        CONTAINER: "internal-Services"
    - require:
      - file: jobserverMonitorPortSetinternal-Services

chowninternal-Services:
  file.directory:
    - name: /opt/containers/internal-Services
    - user: talenduser
    - group: talenduser
    - recurse:
      - user
      - group
    - require:
      - file: createinternal-ServicesService

createinternal-ServicesInit:
  file.copy:
    - name: /etc/init.d/internal-Services
    - source: /opt/containers/internal-Services/bin/internal-Services
  service.running:
    - name: internal-Services-service
    - enable: True
    - init_delay: 60
    - watch:
      - file: /opt/containers/internal-Services/etc/internal-Services-wrapper.conf
    - require:
      - file: chowninternal-Services
      
addlcontainerrenameinternal-Services:
  file.replace:
    - name: /opt/containers/internal-Services/etc/system.properties
    - pattern: karaf.name=trun
    - repl: karaf.name=internal-Services
    - require:
      - file: createinternal-ServicesInit