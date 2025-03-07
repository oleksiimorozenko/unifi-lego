#!/bin/bash

# Set error mode
set -e

# Load environment variables
set -a
source /usr/lib/unifi/data/unifi-lego/unifi-lego.env
set +a

# Setup additional variables for later
LEGO_ARGS="--dns ${DNS_PROVIDER} --email ${CERT_EMAIL} --key-type rsa2048"
LEGO_FORCE_INSTALL=false
RESTART_SERVICES=false

# Show usage
usage() {
	echo "Usage: unifi-lego.sh action [ --restart-services ]"
	echo "Actions:"
	echo "  - unifi-lego.sh create_services: Force (re-)creates systemd service and timer for automated renewal."
	echo "  - unifi-lego.sh initial: Generate new certificate and set up cron job to renew at 03:00 each morning."
	echo "  - unifi-lego.sh install_lego: Force (re-)installs lego, using LEGO_VERSION from unifi-lego.env."
	echo "  - unifi-lego.sh renew: Renew certificate if due for renewal."
	echo "  - unifi-lego.sh update_keystore: Update keystore used by Captive Portal/WiFiman"
	echo "              with either full certificate chain (if NO_BUNDLE='no') or server certificate only (if NO_BUNDLE='yes')."
	echo ""
	echo "Options:"
	echo "  --restart-services: Force restart of services even if certificate was not renewed."
	echo ""
	echo "WARNING: NO_BUNDLE option is only supported experimentally. Setting it to 'yes' is required to make WiFiman work,"
	echo "but may result in some clients not being able to connect to Captive Portal if they do not already have a cached"
	echo "copy of the CA intermediate certificate(s) and are unable to download them."
}

# Get command line options
OPTIONS=$(getopt -o h --long help,restart-services -- "$@")
if [ $? -ne 0 ]; then
	echo "Incorrect option provided"
	exit 1
fi

eval set -- "$OPTIONS"
while [ : ]; do
	case "$1" in
	-h | --help)
		usage
		exit 0
		shift
		;;
	--restart-services)
		RESTART_SERVICES=true
		shift
		;;
	--)
		shift
		break
		;;
	esac
done

create_services() {
	# Create systemd service and timers (for renewal)
	echo "create_services(): Creating unifi-lego systemd service and timer"
	cp -f "${UDM_LE_PATH}/resources/systemd/unifi-lego.service" /etc/systemd/system/unifi-lego.service
	cp -f "${UDM_LE_PATH}/resources/systemd/unifi-lego.timer" /etc/systemd/system/unifi-lego.timer
	systemctl daemon-reload
	systemctl enable unifi-lego.timer
}

deploy_certs() {
	# Deploy certificates for the controller and optionally for the captive portal and radius server

	# Re-write CERT_NAME if it is a wildcard cert. Replace * with _
	LEGO_CERT_NAME=${CERT_NAME/\*/_}
	if [ "$(find -L "${UDM_LE_PATH}"/.lego -type f -name "${LEGO_CERT_NAME}".crt -mmin -5)" ]; then
		echo "deploy_certs(): New certificate was generated, time to deploy it"

		cp -f "${UDM_LE_PATH}"/.lego/certificates/"${LEGO_CERT_NAME}".crt "${UBIOS_CONTROLLER_CERT_PATH}"/unifi.crt
		cp -f "${UDM_LE_PATH}"/.lego/certificates/"${LEGO_CERT_NAME}".key "${UBIOS_CONTROLLER_CERT_PATH}"/unifi.key
		chmod 644 "${UBIOS_CONTROLLER_CERT_PATH}"/unifi.crt "${UBIOS_CONTROLLER_CERT_PATH}"/unifi.key

		if [ "$ENABLE_CAPTIVE" == "yes" ]; then
			update_keystore
		fi

		if [ "$ENABLE_RADIUS" == "yes" ]; then
			cp -f "${UDM_LE_PATH}"/.lego/certificates/"${LEGO_CERT_NAME}".crt "${UBIOS_RADIUS_CERT_PATH}"/server.pem
			cp -f "${UDM_LE_PATH}"/.lego/certificates/"${LEGO_CERT_NAME}".key "${UBIOS_RADIUS_CERT_PATH}"/server-key.pem
			chmod 600 "${UBIOS_RADIUS_CERT_PATH}"/server.pem "${UBIOS_RADIUS_CERT_PATH}"/server-key.pem
		fi

		RESTART_SERVICES=true
	fi
}

restart_services() {
	# Restart services if certificates have been deployed, or we're forcing it on the command line
	if [ "${RESTART_SERVICES}" == true ]; then
		echo "restart_services(): Restarting unifi"
		systemctl restart unifi &>/dev/null

		if [ "$ENABLE_RADIUS" == "yes" ]; then
			echo "restart_services(): Restarting freeradius server"
			systemctl restart freeradius &>/dev/null
		fi
	else
		echo "restart_services(): RESTART_SERVICES is set to false, skipping service restarts"
	fi
}

update_keystore() {
	# Update the java keystore with the new certificate
	if [ "$NO_BUNDLE" == "yes" ]; then
		# Only import server certifcate to keystore. WiFiman requires a single certificate in the .crt file
		# and does not work if the full chain is imported as this includes the CA intermediate certificates.
		echo "update_keystore(): Importing server certificate only"

		# Export only the server certificate from the full chain bundle
		openssl x509 -in "${UNIFIOS_CERT_PATH}"/unifi.crt >"${UNIFIOS_CERT_PATH}"/unifi-server-only.crt

		# Bundle the private key and server-only certificate into a PKCS12 format file
		openssl pkcs12 \
			-export \
			-in "${UNIFIOS_CERT_PATH}"/unifi-server-only.crt \
			-inkey "${UNIFIOS_CERT_PATH}"/unifi.key \
			-name "${UNIFIOS_KEYSTORE_CERT_ALIAS}" \
			-out "${UNIFIOS_KEYSTORE_PATH}"/unifi-key-plus-server-only-cert.p12 \
			-password pass:"${UNIFIOS_KEYSTORE_PASSWORD}"

		# Backup the keystore before editing it.
		cp "${UNIFIOS_KEYSTORE_PATH}/keystore" "${UNIFIOS_KEYSTORE_PATH}/keystore_$(date +"%Y-%m-%d_%Hh%Mm%Ss").backup"

		# Delete the existing full chain from the keystore
		keytool -delete -alias unifi -keystore "${UNIFIOS_KEYSTORE_PATH}/keystore" -deststorepass "${UNIFIOS_KEYSTORE_PASSWORD}"

		# Import the server-only certificate and private key from the PKCS12 file
		keytool -importkeystore \
			-alias "${UNIFIOS_KEYSTORE_CERT_ALIAS}" \
			-destkeypass "${UNIFIOS_KEYSTORE_PASSWORD}" \
			-destkeystore "${UNIFIOS_KEYSTORE_PATH}/keystore" \
			-deststorepass "${UNIFIOS_KEYSTORE_PASSWORD}" \
			-noprompt \
			-srckeystore "${UNIFIOS_KEYSTORE_PATH}/unifi-key-plus-server-only-cert.p12" \
			-srcstorepass "${UNIFIOS_KEYSTORE_PASSWORD}" \
			-srcstoretype PKCS12
	else
		# Import full certificate chain bundle to keystore
		echo "update_keystore(): Importing full certificate chain bundle"
		${CERT_IMPORT_CMD} "${UNIFIOS_CERT_PATH}/unifi.key" "${UNIFIOS_CERT_PATH}/unifi.crt"
	fi
}

install_lego() {
	# Check if lego exists already, do nothing
	if [ ! -f "${LEGO_BINARY}" ] || [ "${LEGO_FORCE_INSTALL}" = true ]; then
		echo "install_lego(): Attempting lego installation"

		# Download and extract lego release
		echo "install_lego(): Downloading lego v${LEGO_VERSION} from ${LEGO_DOWNLOAD_URL}"
		wget -qO "/tmp/lego_release-${LEGO_VERSION}.tar.gz" "${LEGO_DOWNLOAD_URL}"

		echo "install_lego(): Extracting lego binary from release and placing at ${LEGO_BINARY}"
		tar -xozvf "/tmp/lego_release-${LEGO_VERSION}.tar.gz" --directory="${UDM_LE_PATH}" lego

		# Verify lego binary integrity
		echo "install_lego(): Verifying integrity of lego binary"
		LEGO_HASH=$(sha1sum "${LEGO_BINARY}" | awk '{print $1}')
		if [ "${LEGO_HASH}" = "${LEGO_SHA1}" ]; then
			echo "install_lego(): Verified lego v${LEGO_VERSION}:${LEGO_SHA1}"
			chmod +x "${LEGO_BINARY}"
		else
			echo "install_lego(): Verification failure, lego binary sha1 was ${LEGO_HASH}, expected ${LEGO_SHA1}. Cleaning up and aborting"
			rm -f "${UDM_LE_PATH}/lego" "/tmp/lego_release-${LEGO_VERSION}.tar.gz"
			exit 1
		fi
	else
		echo "install_lego(): Lego binary is already installed at ${LEGO_BINARY}, no operation necessary"
	fi
}

# Support alternative DNS resolvers
if [ "${DNS_RESOLVERS}" != "" ]; then
	LEGO_ARGS="${LEGO_ARGS} --dns.resolvers ${DNS_RESOLVERS}"
fi

# Support multiple certificate SANs
for DOMAIN in $(echo $CERT_HOSTS | tr "," "\n"); do
	if [ -z "$CERT_NAME" ]; then
		CERT_NAME=$DOMAIN
	fi
	LEGO_ARGS="${LEGO_ARGS} -d ${DOMAIN}"
done

case $1 in
create_services)
	echo "create_services(): Creating services"
	create_services
	;;
initial)
	install_lego
	create_services
	echo "initial(): Attempting certificate generation"
	echo "initial(): ${LEGO_BINARY} --path \"${LEGO_PATH}\" ${LEGO_ARGS} --accept-tos run"
	${LEGO_BINARY} --path "${LEGO_PATH}" ${LEGO_ARGS} --accept-tos run && deploy_certs && restart_services
	echo "initial(): Starting unifi-lego systemd timer"
	systemctl start unifi-lego.timer
	;;
install_lego)
	echo "install_lego(): Forcing installation of lego"
	LEGO_FORCE_INSTALL=true
	install_lego
	;;
renew)
	echo "renew(): Attempting certificate renewal"
	echo "renew(): ${LEGO_BINARY} --path \"${LEGO_PATH}\" ${LEGO_ARGS} renew --days 60"
	${LEGO_BINARY} --path "${LEGO_PATH}" ${LEGO_ARGS} renew --days 60 && deploy_certs && restart_services
	;;
test_deploy)
	echo "test_deploy(): Attempting to deploy certificate"
	deploy_certs
	;;
update_keystore)
	echo "update_keystore(): Attempting to update keystore used by hotspot Captive Portal and WiFiman"
	RESTART_SERVICES=true
	update_keystore && restart_services
	;;
*)
	echo "ERROR: No valid action provided."
	usage
	exit 1
	;;
esac
