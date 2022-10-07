#!/bin/bash

# InfluxMyHeizung, zum Ermitteln der Temperaturunterschiede zwischen Heisswassersträngen
# im Vorlauf und Rücklauf mit nachgelagerter Auswertbarkeit z.B. in Grafana.
# Daten werden mit dem ESP D1-Mini erhoben und mehreren DS18B20 wie beschrieben
# unter https://tasmota.github.io/docs/DS18x20/

# Könnte ja mal sein, dass man mal Klartext braucht auf der CLI
if [ "$1" = "debug" ] ; then DEBUG=1 ; else DEBUG=0 ; fi

# Ich übersetze die Befehle, weil auf einem Ubuntu oder einem CentOS oder einem Raspberry-Image die Befehle an
# unterschiedlichen Stellen liegen können. So kann ich dieses Skript in 5 oder 10 Jahren auf einer beliebigen
# anderen Distribution einfach weiter laufen lassen.
DATE=`which date`
JQ=`which jq`
WGET=`which wget`
CURL=`which curl`
PIDOF=`which pidof`
NC=`which nc`

# Da ich dieses skript per Crontab ständig abfeuere, soll es zu keinen Überlappungen kommen
if [ $($PIDOF -x "$0" | wc -w) -ne 2 ] ; then exit ; fi

# Die INFLUX-Variablen sind für das Schreiben in die Influx >V2
# Der ESP mit Tasmota Firmware wird definiert
ESP=192.168.x.y
INFLUXRASPI=192.168.x.z:8086
INFLUXRASPIORG=****
INFLUXRASPIBUCKET=****
INFLUXRASPITOKEN=****

# Skript-Abbruch, wenn der ESP nicht erreichbar ist
# Prüfung per nc auf Port 80
if $(nc -z -w2 ${ESP} 80) ; then

  # Alle JSON Informationen aus dem Tasmota auslesen und später per echo $JSON verarbeiten
  JSON=$($CURL -s ${ESP}/cm?cmnd=status%2010)
  JSON5=$($CURL -s ${ESP}/cm?cmnd=status%205)
  JSON11=$($CURL -s ${ESP}/cm?cmnd=status%2011)

  # Wie hast du deinen Tasmota genannt? So taucht er im Influx/Grafana auf
  ESPHOSTNAME=$(echo $JSON5 | $JQ -r '."StatusNET"."Hostname"')
  
  # RSSI und Signal Werte aus dem tasmota ESP Image auslesen
  ESPRSSI=$(echo $JSON11 | $JQ -r '."StatusSTS"."Wifi"."RSSI"')
  ESPSIGNAL=$(echo $JSON11 | $JQ -r '."StatusSTS"."Wifi"."Signal"')

  # Alternativ könnte man die EPOCH Uhrzeit aus dem JSON des ESP nehmen, aber das impliziert
  # ein sauberes anpassen der Zeitzonen. Also lieber das EPOCH vom Rechner nehmen, der das hier ausführt
  # EPOCH=$(LC_TIME="de_DE.UTF-8" date -d $(echo $JSON | $JQ -r '.StatusSNS.Time') +%s)
  EPOCH=$(date +%s)

  # Wenn nur ein DS18B20 angeschlossen ist, heisst der auch nur so. Sind mehrere aktiv, dann haben alle
  # Sensoren noch einen Bindestrich und eine Zahl hinten dran und starten ab der 1, also "DS18B20-1"
  SENSOREN=$(echo $JSON | $JQ -r '.StatusSNS | to_entries[] | select( .key | contains("DS18B20")) | .key')
else
  echo "# --- ESP $ESP nicht erreichbar."
  exit
fi

for SENSOR in $SENSOREN ; do
  SENSORNAME="null"
  TEMPERATUR="null"

  # Klar, kann man das schöner programmieren, aber so verstehts halt direkt jeder - Vor allem ich in 2 Jahren!
  # Die doppelte Maskierung um den $SENSOR ist, um Fehler in der Auswertung im jq zu vermeiden (Bindestrich)
  # Ersetze hier die "000000000000" mit den IDs deiner Sensoren und je SENSORNAME, was der Sensor misst.
  if [ "$(echo $JSON | $JQ -r '.StatusSNS."'$SENSOR'".Id')" == "000000000000" ] ; then SENSORNAME="Heizungskeller"  ; fi
  if [ "$(echo $JSON | $JQ -r '.StatusSNS."'$SENSOR'".Id')" == "000000000000" ] ; then SENSORNAME="FBH_Rücklauf" ; fi
  if [ "$(echo $JSON | $JQ -r '.StatusSNS."'$SENSOR'".Id')" == "000000000000" ] ; then SENSORNAME="FBH_Vorlauf" ; fi
  if [ "$(echo $JSON | $JQ -r '.StatusSNS."'$SENSOR'".Id')" == "000000000000" ] ; then SENSORNAME="Heizkörper_Vorlauf"  ; fi
  if [ "$(echo $JSON | $JQ -r '.StatusSNS."'$SENSOR'".Id')" == "000000000000" ] ; then SENSORNAME="Heizkörper_Rücklauf"  ; fi
  if [ "$(echo $JSON | $JQ -r '.StatusSNS."'$SENSOR'".Id')" == "000000000000" ] ; then SENSORNAME="Zirkulation" ; fi
  if [ "$(echo $JSON | $JQ -r '.StatusSNS."'$SENSOR'".Id')" == "000000000000" ] ; then SENSORNAME="Heißwasser" ; fi
  if [ "$SENSORNAME" != "null" ] ; then

    TEMPERATUR=$(echo $JSON | $JQ -r '.StatusSNS."'$SENSOR'".Temperature')
    # Debug Ausgabe, wenn der gefundene Sensor in diesem Loop ist
    if [ $DEBUG -eq 1 ] ; then
      echo "# --- Es sind $TEMPERATUR °C an $SENSORNAME"
    fi

    # Schreiben des Temperaturwertes in die InfluxDB
    $CURL --request POST "http://${INFLUXRASPI}/api/v2/write?org=${INFLUXRASPIORG}&bucket=${INFLUXRASPIBUCKET}&precision=s" --header "Authorization: Token ${INFLUXRASPITOKEN}" --data-raw "${ESPHOSTNAME} ${SENSORNAME}=${TEMPERATUR} ${EPOCH}"

  else

    # Debug Ausgabe, wenn der Sensor in diesem Loop nicht gefunden wird
    if [ $DEBUG -eq 1 ] ; then
      TEMPERATUR=$(echo $JSON | $JQ -r '.StatusSNS."'$SENSOR'".Temperature')
      echo "# --- Ein Sensor hat $TEMPERATUR °C und den Namen $SENSOR und die ID $(echo $JSON | $JQ -r '.StatusSNS."'$SENSOR'".Id')"
    fi
  fi
done

# Falls man das alles mal auf der CLI sehen möchte
if [ $DEBUG -eq 1 ] ; then echo "# --- Sensor $ESPHOSTNAME RSSI: $ESPRSSI Signal: $ESPSIGNAL" ; fi

# RSSI und Signal Werte aus dem tasmota ESP Image speichern
$CURL --request POST "http://${INFLUXRASPI}/api/v2/write?org=${INFLUXRASPIORG}&bucket=${INFLUXRASPIBUCKET}&precision=s" --header "Authorization: Token ${INFLUXRASPITOKEN}" --data-raw "${ESPHOSTNAME} RSSI=${ESPRSSI} ${EPOCH}"
$CURL --request POST "http://${INFLUXRASPI}/api/v2/write?org=${INFLUXRASPIORG}&bucket=${INFLUXRASPIBUCKET}&precision=s" --header "Authorization: Token ${INFLUXRASPITOKEN}" --data-raw "${ESPHOSTNAME} Signal=${ESPSIGNAL} ${EPOCH}"

exit 0
