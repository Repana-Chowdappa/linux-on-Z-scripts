#!/bin/bash
# ©  Copyright IBM Corporation 2021.
# LICENSE: Apache License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0)
#
# Instructions:
# Download build script: wget https://raw.githubusercontent.com/linux-on-ibm-z/scripts/master/strimzi-kafka-bridge/0.20.2/build_strimzi-kafka-bridge.sh
# Execute build script: bash build_strimzi-kafka-bridge.sh    (provide -h for help)
#

USER_IN_GROUP_DOCKER=$(id -nGz $USER | tr '\0' '\n' | grep '^docker$' | wc -l)
set -e -o pipefail

PACKAGE_NAME="strimzi-kafka-bridge"
PACKAGE_VERSION="0.20.2"
PATCH_URL="https://raw.githubusercontent.com/linux-on-ibm-z/scripts/master/${PACKAGE_NAME}/${PACKAGE_VERSION}/patch"
FORCE="false"
TESTS="false"
CURDIR="$(pwd)"
CURPATH="$(echo $PATH)"
LOG_FILE="${CURDIR}/logs/${PACKAGE_NAME}-${PACKAGE_VERSION}-$(date +"%F-%T").log"
NON_ROOT_USER="$(whoami)"
JAVA_PROVIDED="OpenJDK11"
BUILD_ENV="$HOME/setenv.sh"
BUILD_DOCKER_IMAGE="N"
PUSH_TO_REGISTRY="N"
INSECURE_REGISTRY="N"
REGISTRY_NEED_LOGIN="N"
DOCKER_DJSON_FILE="/etc/docker/daemon.json"
S390X_JNI_JAR_DIR="/tmp/opertemp/libs"
#export DOCKER_ORG=your_username_on_docker_registry
#export DOCKER_REGISTRY=registry_url
#export REGISTRY_PASS=your_password_on_docker_registry

trap cleanup 1 2 ERR

#Check if directory exists
if [ ! -d "$CURDIR/logs/" ]; then
        mkdir -p "$CURDIR/logs/"
fi

if [ -f "/etc/os-release" ]; then
        source "/etc/os-release"
fi

function prepare() {
        if command -v "sudo" >/dev/null; then
                printf -- 'Sudo : Yes\n'
        else
                printf -- 'Sudo : No \n'
                printf -- 'You can install the same from installing sudo from repository using apt, yum or zypper based on your distro. \n'
                exit 1
        fi

        if [[ "$JAVA_PROVIDED" != "AdoptJDK11_openj9" && "$JAVA_PROVIDED" != "AdoptJDK11_hotspot" && "$JAVA_PROVIDED" != "OpenJDK11" ]]; then
                printf "$JAVA_PROVIDED is not supported, Please use valid java from {AdoptJDK11_openj9, AdoptJDK11_hotspot, OpenJDK11} only\n"
                exit 1
        fi

        if [[ "$PUSH_TO_REGISTRY" == "Y" ]]; then  
            if [[ "$DOCKER_REGISTRY" == "" || "$DOCKER_ORG" == "" ]]; then
                printf "DOCKER_REGISTRY or DOCKER_ORG is not set yet, Please set up corresponding environment variables\n"
                exit 1
            fi

            if [[ "$REGISTRY_NEED_LOGIN" == "Y" && "$REGISTRY_PASS" == "" ]]; then
                printf "REGISTRY_PASS is not set yet, Please set up corresponding environment variables\n"
                exit 1
            fi
        fi

        if [[ "$BUILD_DOCKER_IMAGE" == "Y" ]]; then
            if [[ "$USER_IN_GROUP_DOCKER" == "1" ]]; then
                printf "User $USER belongs to group docker\n" |& tee -a "${LOG_FILE}"
            else
                printf "Please ensure User $USER belongs to group docker\n"
                exit 1
            fi
        fi

        if [[ "$FORCE" == "true" ]]; then
                printf -- 'Force attribute provided hence continuing with install without confirmation message\n' |& tee -a "${LOG_FILE}"
        else
                # Ask user for prerequisite installation
                printf -- "\nAs part of the installation, dependencies would be installed/upgraded. \n"
                while true; do
                        read -r -p "Do you want to continue (y/n) ? :  " yn
                        case $yn in
                        [Yy]*)
                                printf -- 'User responded with Yes. \n' |& tee -a "${LOG_FILE}"
                                break
                                ;;
                        [Nn]*) exit ;;
                        *) echo "Please provide confirmation to proceed." ;;
                        esac
                done
        fi

        # zero out
        true > "$BUILD_ENV"
}

function cleanup() {
        sudo rm -rf "${CURDIR}/apache-maven-3.8.2-bin.tar.gz" "${CURDIR}/adoptjdk.tar.gz" "${CURDIR}/OpenJDK8U-jdk*.tar.gz" "${CURDIR}/sbt.tgz"
        printf -- 'Cleaned up the artifacts\n' >>"${LOG_FILE}"
}

function setupGCC()
{
        sudo update-alternatives --install /usr/bin/cc cc /usr/bin/gcc-7 40
        sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-7 40
        sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-7 40
        sudo update-alternatives --install /usr/bin/c++ c++ /usr/bin/g++-7 40
}

function buildGCC()
{
        local ver=7.3.0
        local url
        printf -- "Building GCC $ver"

        cd $CURDIR
        url=http://ftp.mirrorservice.org/sites/sourceware.org/pub/gcc/releases/gcc-${ver}/gcc-${ver}.tar.gz
        curl -sSL $url | tar xzf - || error "gcc $ver"

        cd gcc-${ver}
        ./contrib/download_prerequisites
        mkdir build-gcc; cd build-gcc
        ../configure --enable-languages=c,c++ --disable-multilib
        make -j$(nproc)
        sudo make install

        sudo update-alternatives --install /usr/bin/cc cc /usr/local/bin/gcc-7 40
        sudo update-alternatives --install /usr/bin/gcc gcc /usr/local/bin/gcc-7 40
        sudo update-alternatives --install /usr/bin/g++ g++ /usr/local/bin/g++-7 40
        sudo update-alternatives --install /usr/bin/c++ c++ /usr/local/bin/g++-7 40
}

function configureAndInstall() {

        printf -- 'Configuration and Installation started \n'

        printf -- "Building zstd-jni require java 8: Installing AdoptOpenJDK8 + OpenJ9 with Large heap \n"
        cd $CURDIR
        wget https://github.com/AdoptOpenJDK/openjdk8-binaries/releases/download/jdk8u282-b08_openj9-0.24.0/OpenJDK8U-jdk_s390x_linux_openj9_linuxXL_8u282b08_openj9-0.24.0.tar.gz
        sudo tar zxf OpenJDK8U-jdk_s390x_linux_openj9_linuxXL_8u282b08_openj9-0.24.0.tar.gz -C /opt/
        export JAVA_HOME=/opt/jdk8u282-b08
        export PATH=$JAVA_HOME/bin:$CURPATH
        printf -- "Java version is :\n"
        java -version

        mkdir -p $S390X_JNI_JAR_DIR

        if [[ "$TESTS" == "true" ]]; then
            #Install dependencies for building rocksdbjni
            case "$DISTRO" in
            "ubuntu-18.04" | "ubuntu-20.04" | "ubuntu-21.04")
                printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO"
                sudo apt-get update
                sudo apt-get install -y unzip zlib1g-dev libbz2-dev liblz4-dev libzstd-dev
                ;;

            "rhel-7.8" | "rhel-7.9" | "rhel-8.2" | "rhel-8.3" | "rhel-8.4")
                printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO"
                sudo yum install -y hostname unzip procps snappy binutils bzip2 bzip2-devel zlib-devel diffutils
                ;;

            "sles-12.5")
                printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO"
                sudo zypper install -y unzip snappy-devel libzip2 bzip2 zlib-devel
                ;;

            "sles-15.2" | "sles-15.3")
                printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO"
                sudo zypper install -y unzip snappy-devel libzip5 bzip2 zlib-devel gzip gawk
                ;;
            esac

            # Build and Create rocksdbjni-5.18.4.jar for s390x
            printf -- "Build and Create rocksdbjni-5.18.4.jar for s390x\n"
            cd $CURDIR
            git clone https://github.com/facebook/rocksdb.git
            cd rocksdb
            git checkout v5.18.4
            sed -i '1656s/ARCH/MACHINE/g' Makefile
            PORTABLE=1 make shared_lib
            make rocksdbjava
            printf -- "Built rocksdb and created rocksdbjni-5.18.4.jar successfully.\n"
            # Store rocksdbjni.jar in a temporary directory
            cp -f java/target/rocksdbjni-5.18.4-linux64.jar $S390X_JNI_JAR_DIR/rocksdbjni-5.18.4.jar
            sha1sum $S390X_JNI_JAR_DIR/rocksdbjni-5.18.4.jar > $S390X_JNI_JAR_DIR/rocksdbjni-5.18.4.jar.sha1
            sed -i "s/ .*$//g" $S390X_JNI_JAR_DIR/rocksdbjni-5.18.4.jar.sha1
        fi

        # Build and create zstd-jni-1.4.5-6.jar for s390x
        printf -- "Build and create zstd-jni-1.4.5-6.jar for s390x\n"
        # Install SBT (required for Zstd JNI)
        cd $CURDIR
        wget -O sbt.tgz https://github.com/sbt/sbt/releases/download/v1.3.13/sbt-1.3.13.tgz
        tar -zxvf sbt.tgz
        export PATH=${PATH}:$CURDIR/sbt/bin/

        # Build SBT-JNI 
        cd $CURDIR
        git clone https://github.com/joprice/sbt-jni.git
        cd sbt-jni/ && git checkout v0.2.0
        sbt compile package && sbt +publishLocal

        # Build Zstd JNI
        cd $CURDIR
        git clone -b v1.4.5-6 https://github.com/luben/zstd-jni.git
        cd zstd-jni
        wget -O - "https://raw.githubusercontent.com/linux-on-ibm-z/scripts/master/ApacheSpark/3.0.1/patch/ZstdBuild.diff" | git apply
        sbt compile package
        # Store zstd-jni.jar in a temporary directory
        cp -f target/zstd-jni-1.4.5-6.jar $S390X_JNI_JAR_DIR/zstd-jni-1.4.5-6.jar
        sha1sum $S390X_JNI_JAR_DIR/zstd-jni-1.4.5-6.jar > $S390X_JNI_JAR_DIR/zstd-jni-1.4.5-6.jar.sha1
        sed -i "s/ .*$//g" $S390X_JNI_JAR_DIR/zstd-jni-1.4.5-6.jar.sha1
        export PATH=$CURPATH

        if [[ "${ID}" == "sles" || "${ID}" == "ubuntu" || ${DISTRO} =~ rhel-7\.[8-9] ]]; then
            # Install maven-3.8.2
            cd $CURDIR
            wget https://archive.apache.org/dist/maven/maven-3/3.8.2/binaries/apache-maven-3.8.2-bin.tar.gz
            tar -zxf apache-maven-3.8.2-bin.tar.gz
            export PATH=$CURDIR/apache-maven-3.8.2/bin:$PATH
        fi

        if [[ "$BUILD_DOCKER_IMAGE" == "Y" ]]; then
            # Start docker service
            printf -- "Starting docker service\n"
            sudo service docker start
            sleep 20s
            if [[ $INSECURE_REGISTRY == "Y" ]]; then
                if [ ! -f $DOCKER_DJSON_FILE ]; then
                    sudo mkdir -p /etc/docker
                    sudo touch $DOCKER_DJSON_FILE
                fi
                sudo chmod 666 $DOCKER_DJSON_FILE
                if [[ "${ID}" == "sles" ]]; then
                    cd $CURDIR
                    wget --no-check-certificate $PATCH_URL/daemon.json
                    sed -i "s/INSECUREREGISTRY/${DOCKER_REGISTRY}/g" daemon.json
                    sudo mv -f daemon.json $DOCKER_DJSON_FILE
                else
                    sudo printf "{\n\"insecure-registries\": [\"${DOCKER_REGISTRY}\"]\n}\n" >> $DOCKER_DJSON_FILE
                fi
                sudo service docker restart
                sleep 20s
            fi

            if [[ $REGISTRY_NEED_LOGIN == "Y" ]]; then
                printf -- "Login to ${DOCKER_REGISTRY}\n"
                docker login --username=$DOCKER_ORG --password=$REGISTRY_PASS $DOCKER_REGISTRY
            fi

            # Install Docker Buildx for Ubuntu and SLES
            if [[ "${ID}" == "ubuntu" ]] || [[ "${ID}" == "sles" ]]; then
                printf -- "Installing Docker Buildx\n"
                cd $CURDIR
                wget https://github.com/docker/buildx/releases/download/v0.6.1/buildx-v0.6.1.linux-s390x
                mkdir -p ~/.docker/cli-plugins
                mv buildx-v0.6.1.linux-s390x ~/.docker/cli-plugins/docker-buildx
                chmod a+x ~/.docker/cli-plugins/docker-buildx
            fi
        fi

        if [[ "$JAVA_PROVIDED" == "AdoptJDK11_openj9" ]]; then
                # Install AdoptOpenJDK 11 (With OpenJ9)
                cd "$CURDIR"
                sudo mkdir -p /opt/adopt/java

                curl -SL -o adoptjdk.tar.gz https://github.com/AdoptOpenJDK/semeru11-binaries/releases/download/jdk-11.0.12%2B7_openj9-0.27.0/ibm-semeru-open-jdk_s390x_linux_11.0.12_7_openj9-0.27.0.tar.gz
                # Everytime new jdk is downloaded, Ensure that --strip valueis correct
                sudo tar -zxvf adoptjdk.tar.gz -C /opt/adopt/java --strip-components 1

                export JAVA_HOME=/opt/adopt/java

                printf -- "export JAVA_HOME=/opt/adopt/java\n" >> "$BUILD_ENV"
                printf -- "Installation of AdoptOpenJDK 11 (With OpenJ9) is successful\n" >> "$LOG_FILE"

        elif [[ "$JAVA_PROVIDED" == "AdoptJDK11_hotspot" ]]; then
                # Install AdoptOpenJDK 11 (With Hotspot)
                cd "$CURDIR"
                sudo mkdir -p /opt/adopt/java

                curl -SL -o adoptjdk.tar.gz https://github.com/adoptium/temurin11-binaries/releases/download/jdk-11.0.12%2B7/OpenJDK11U-jdk_s390x_linux_hotspot_11.0.12_7.tar.gz
                # Everytime new jdk is downloaded, Ensure that --strip valueis correct
                sudo tar -zxvf adoptjdk.tar.gz -C /opt/adopt/java --strip-components 1

                export JAVA_HOME=/opt/adopt/java

                printf -- "export JAVA_HOME=/opt/adopt/java\n" >> "$BUILD_ENV"
                printf -- "Installation of AdoptOpenJDK 11 (With Hotspot) is successful\n" >> "$LOG_FILE"

        elif [[ "$JAVA_PROVIDED" == "OpenJDK11" ]]; then
                if [[ "${ID}" == "ubuntu" ]]; then
                        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-11-jdk
                        export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-s390x
                        printf -- "export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-s390x\n" >> "$BUILD_ENV"
                elif [[ "${ID}" == "rhel" ]]; then
                        sudo yum install -y java-11-openjdk java-11-openjdk-devel
                        echo "Inside $DISTRO"
                        export JAVA_HOME=/usr/lib/jvm/java-11-openjdk
                        printf -- "export JAVA_HOME=/usr/lib/jvm/java-11-openjdk\n" >> "$BUILD_ENV"
                elif [[ "${ID}" == "sles" ]]; then
                        sudo zypper install -y java-11-openjdk java-11-openjdk-devel
                        export JAVA_HOME=/usr/lib64/jvm/java-11-openjdk
                        printf -- "export JAVA_HOME=/usr/lib64/jvm/java-11-openjdk\n" >> "$BUILD_ENV"
                fi
                printf -- "Installation of OpenJDK 11 is successful\n" >> "$LOG_FILE"
        else
                printf "$JAVA_PROVIDED is not supported, Please use valid java from {AdoptJDK11_openj9, AdoptJDK11_hotspot, OpenJDK11} only"
                exit 1
        fi
        printf -- "export PATH=$JAVA_HOME/bin:$PATH\n" >> "$BUILD_ENV"
        export PATH=$JAVA_HOME/bin:$PATH
        java -version |& tee -a "$LOG_FILE"
    
        #Building Strimzi-kafka-bridge binary and image, push the image to DOCKER_REGISTRY
        printf -- "Building Strimzi-kafka-bridge binary and image\n"
        cd $CURDIR
        wget --no-check-certificate $PATCH_URL/bridge.diff
        if [[ "$BUILD_DOCKER_IMAGE" == "Y" ]]; then 
            export DOCKER_TAG=$PACKAGE_VERSION
            printf -- "export DOCKER_ORG=$DOCKER_ORG\n" >> "$BUILD_ENV"
            printf -- "export DOCKER_REGISTRY=$DOCKER_REGISTRY\n" >> "$BUILD_ENV"
            printf -- "export DOCKER_TAG=$PACKAGE_VERSION\n" >> "$BUILD_ENV"
            export DOCKER_BUILDX=buildx
            printf -- "export DOCKER_BUILDX=buildx\n" >> "$BUILD_ENV"
            export DOCKER_BUILD_ARGS="--platform linux/s390x --load"
            printf -- "export DOCKER_BUILD_ARGS=\"--platform linux/s390x --load\"\n" >> "$BUILD_ENV"
        fi
        git clone https://github.com/strimzi/strimzi-kafka-bridge.git
        cd strimzi-kafka-bridge/
        git checkout $PACKAGE_VERSION
        patch -p1 < ${CURDIR}/bridge.diff
        if [[ "$PUSH_TO_REGISTRY" == "Y" ]]; then 
            make MVN_ARGS='-DskipTests' all
        elif [[ "$BUILD_DOCKER_IMAGE" == "Y" ]]; then
            make MVN_ARGS='-DskipTests' java_package docker_build
        else
            make MVN_ARGS='-DskipTests' java_package
        fi
        cp -r target/kafka-bridge-$PACKAGE_VERSION/kafka-bridge-$PACKAGE_VERSION ${CURDIR}/

        # run tests
        runTest
        
	# Cleanup
        cleanup
        
        printf -- "%s installation completed. Please check the Usage.\n" "$PACKAGE_NAME"
}

function runTest() {
	set +e
	if [[ "$TESTS" == "true" ]]; then
                #Replace all other jni jar files with the s390x version peers
                printf -- "Replacing other jni jar files with the s390x version peers\n"
                cp -f $S390X_JNI_JAR_DIR/zstd-jni-1.4.5-6.jar $HOME/.m2/repository/com/github/luben/zstd-jni/1.4.5-6/zstd-jni-1.4.5-6.jar
                cp -f $S390X_JNI_JAR_DIR/zstd-jni-1.4.5-6.jar.sha1 $HOME/.m2/repository/com/github/luben/zstd-jni/1.4.5-6/zstd-jni-1.4.5-6.jar.sha1

                printf -- "TEST Flag is set, Preparing the kafka server for testing \n" >> "$LOG_FILE"
                cd ${CURDIR}
                wget --no-check-certificate $PATCH_URL/kafka_config.diff
                wget https://archive.apache.org/dist/kafka/2.8.0/kafka_2.13-2.8.0.tgz
                tar xvf kafka_2.13-2.8.0.tgz
                cd kafka_2.13-2.8.0
                cp -f $S390X_JNI_JAR_DIR/rocksdbjni-5.18.4.jar libs/
                patch -p1 < ${CURDIR}/kafka_config.diff

                printf -- "Starting the kafka server\n" >> "$LOG_FILE"
                bin/zookeeper-server-start.sh config/zookeeper.properties >/dev/null 2>&1 &
                sleep 20s
                bin/kafka-server-start.sh config/server.properties >/dev/null 2>&1 &
                sleep 60s

	        printf -- "TEST Flag is set, continue with running test \n"  >> "$LOG_FILE"
	        cd ${CURDIR}/strimzi-kafka-bridge
                mvn test
                printf -- "Tests completed. \n" 

                printf -- "Shutting down the kafka server\n" >> "$LOG_FILE"
                cd ${CURDIR}/kafka_2.13-2.8.0
                bin/kafka-server-stop.sh >/dev/null 2>&1 &
                sleep 30s
                bin/zookeeper-server-stop.sh >/dev/null 2>&1 &
                sleep 10s
	fi
	set -e
}

function logDetails() {
        printf -- '**************************** SYSTEM DETAILS *************************************************************\n' >"$LOG_FILE"
        if [ -f "/etc/os-release" ]; then
                cat "/etc/os-release" >>"$LOG_FILE"
        fi
        cat /proc/version >>"$LOG_FILE"
        printf -- '*********************************************************************************************************\n' >>"$LOG_FILE"
        printf -- "Detected %s \n" "$PRETTY_NAME"
        printf -- "Request details : PACKAGE NAME= %s , VERSION= %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" |& tee -a "$LOG_FILE"
}

# Print the usage message
function printHelp() {
        echo
        echo "Usage: "
        echo "Please set up environment variables DOCKER_REGISTRY, DOCKER_ORG, DOCKERHUB_USER and DOCKERHUB_PASS first, ensure user $USER belongs to group docker."
        echo "  build_strimzi.sh  [-d debug] [-y install-without-confirmation] [-t run-test] [-i insecure-registry] [-l registry-need-login] [-m build-docker-image] [-p push-to-registry] [-j Java to use from {AdoptJDK11_openj9, AdoptJDK11_hotspot, OpenJDK11}]"
        echo "  default: If no -j specified, openjdk-11 will be installed"
        echo
}

while getopts "h?dytilmpj:" opt; do
        case "$opt" in
        h | \?)
                printHelp
                exit 0
                ;;
        d)
                set -x
                ;;
        y)
                FORCE="true"
                ;;
        t)
                TESTS="true"
                ;;
        i)
                INSECURE_REGISTRY="Y"
                ;;
        l)
                REGISTRY_NEED_LOGIN="Y"
                ;;
        m)
                BUILD_DOCKER_IMAGE="Y"
                ;;
        p)
                PUSH_TO_REGISTRY="Y"
                ;;
        j)
                JAVA_PROVIDED="$OPTARG"
                ;;
        esac
done

function gettingStarted() {
        printf -- '\n********************************************************************************************************\n'
        printf -- "\n* Getting Started * \n"
        printf -- "Note: Environmental Variables needed have been added to $HOME/setenv.sh\n"
        printf -- "Note: To set the Environmental Variables needed for Strimzi-kafka-bridge, please run: source $HOME/setenv.sh \n\n"
        if [[ "$PUSH_TO_REGISTRY" == "Y" ]]; then 
            printf -- "You can use the Strimzi Kafka operator to deploy the Kafka Bridge with HTTP support on Kubernetes and OpenShift \n"
        fi
        printf -- "If you want to run the Kafka Bridge locally, please run the following commands to edit the configuration: \n"
        printf -- "    cd $CURDIR/kafka-bridge-$PACKAGE_VERSION && vi config/application.properties \n\n"
        printf -- "Once your configuration is ready, start the bridge using:: \n"
        printf -- "    bin/kafka_bridge_run.sh --config-file config/application.properties \n\n"
        printf -- "Visit https://strimzi.io/docs/bridge/latest/ for more information.\n\n"
        printf -- '********************************************************************************************************\n'
}

###############################################################################################################

logDetails
prepare

DISTRO="$ID-$VERSION_ID"
case "$DISTRO" in
"ubuntu-18.04" | "ubuntu-20.04" | "ubuntu-21.04")
        printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "${LOG_FILE}"
        sudo apt-get update
        sudo apt-get install -y git make gcc-7 g++-7 tar wget patch curl |& tee -a "${LOG_FILE}"
        if [[ "$BUILD_DOCKER_IMAGE" == "Y" ]]; then 
            sudo apt-get install -y docker.io |& tee -a "${LOG_FILE}"
        fi
        setupGCC
        configureAndInstall |& tee -a "${LOG_FILE}"
        ;;

"rhel-7.8" | "rhel-7.9")
        printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "${LOG_FILE}"
        sudo yum install -y git make autoconf gcc gcc-c++ tar wget patch curl bzip2 |& tee -a "${LOG_FILE}"
        if [[ "$BUILD_DOCKER_IMAGE" == "Y" ]]; then 
            sudo yum install -y yum-utils |& tee -a "${LOG_FILE}"
            sudo yum-config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
            sudo yum-config-manager --enable docker-ce-stable
            sudo yum install -y docker-ce |& tee -a "${LOG_FILE}"
        fi
        buildGCC |& tee -a "$LOG_FILE"
        configureAndInstall |& tee -a "${LOG_FILE}"
        ;;

"rhel-8.2" | "rhel-8.3" | "rhel-8.4")
        printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "${LOG_FILE}"
        sudo yum install -y git make gcc gcc-c++ tar wget patch maven curl hostname binutils |& tee -a "${LOG_FILE}"
        if [[ "$BUILD_DOCKER_IMAGE" == "Y" ]]; then 
            sudo yum remove -y podman buildah |& tee -a "${LOG_FILE}"
            sudo yum install -y yum-utils |& tee -a "${LOG_FILE}"
            sudo yum-config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
            sudo yum install -y docker-ce docker-ce-cli containerd.io |& tee -a "${LOG_FILE}"
        fi
        configureAndInstall |& tee -a "${LOG_FILE}"
        ;;

"sles-12.5")
        printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "${LOG_FILE}"
        sudo zypper install -y git gcc7 gcc7-c++ make autoconf tar wget patch curl which |& tee -a "${LOG_FILE}"
        if [[ "$BUILD_DOCKER_IMAGE" == "Y" ]]; then
            sudo zypper install -y  docker-20.10.6_ce-98.66.1 |& tee -a "${LOG_FILE}"
        fi
        setupGCC
        configureAndInstall |& tee -a "${LOG_FILE}"
        ;;

"sles-15.2" | "sles-15.3")
        printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "${LOG_FILE}"
        sudo zypper install -y git gcc gcc-c++ make tar wget patch curl which |& tee -a "${LOG_FILE}"
        if [[ "$BUILD_DOCKER_IMAGE" == "Y" ]]; then
            sudo zypper install -y  docker-20.10.6_ce-6.49.3 |& tee -a "${LOG_FILE}"
        fi
        configureAndInstall |& tee -a "${LOG_FILE}"
        ;;

*)
        printf -- "%s not supported \n" "$DISTRO" |& tee -a "${LOG_FILE}"
        exit 1

        ;;
esac

gettingStarted |& tee -a "${LOG_FILE}"
