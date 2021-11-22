#!/bin/bash
#set -x

# Edit the below variable to set the time in seconds between sending another email.
# To avoid spam, suggested interval is at 5 mins (300), but 15 min (900) is probably
# more reasonable.
FREQUENCY=900
# Update this list with your list of masternodes protx submit hash, leave a space
# between each one, they must all be on a single unbroken line.
MY_MASTERNODES=(

)
PROG="$0"

# Checks that the required software is installed on this machine.
check_dependencies(){

	nc -h >/dev/null 2>&1 || progs+=" netcat"
	jq -V >/dev/null 2>&1 || progs+=" jq"

	if [[ -n $progs ]];then
		text="$PROG	Missing applications on your system, please run\n\n"
		text+="sudo apt install $progs\n\nbefore running this program again."
		echo -e "$text" >&2
		exit 1
	fi
}
check_dependencies

# This variable gets updated after an incident occurs.
LAST_SENT_TIME=1636283113

> ./tmp/block_ip_ch
> ./tmp/poseban_ip_ch

#####
all_mns_list=$(dash-cli protx list registered 1)
while read proTxHash registeredHeight PoSeBanHeight lastPaidHeight PoSeRevivedHeight payoutAddress service PoSePenalty junk;do
	proTxHash=$proTxHash				# protx info текущей MN
	registeredHeight=$registeredHeight	#  registeredHeight
	PoSeBanHeight=$PoSeBanHeight			# PoSeBan
	PoSeRevivedHeight=$PoSeRevivedHeight	# перерегистрация MN
	lastPaidHeight=$lastPaidHeight	#  последней выплаты
	payoutAddress=$payoutAddress
	ipPort=$(awk -F: '{print $1}' <<< "$service")	# ip 
	PoSePenalty=$PoSePenalty
	if [ "$PoSeBanHeight" -eq -1 ];then
		if [ "$PoSeRevivedHeight"  -lt "$lastPaidHeight" ];then
				if (( "$lastPaidHeight" > 0 )); then
					block=$(echo "$lastPaidHeight")
				else
					block=$(echo "$registeredHeight")
				fi
		else 
			block=$(echo "$PoSeRevivedHeight")
		fi
	echo "$block $proTxHash $payoutAddress $ipPort $lastPaidHeight" >> ./tmp/block_ip_ch
	else 
		echo $proTxHash $ipPort >> ./tmp/poseban_ip_ch		
	fi
done < <(jq -r '.[]|"\(.proTxHash) \(.state.registeredHeight) \(.state.PoSeBanHeight) \(.state.lastPaidHeight) \(.state.PoSeRevivedHeight) \(.state.payoutAddress) \(.state.service) \(.state.PoSePenalty)"' <<< "$all_mns_list") | sort -n -k2 | awk '{print NR " " $0}'
######
block_ip_ch=$(cat ./tmp/block_ip_ch)
totalAmountMN=$(echo "$block_ip_ch" | wc -l)
# queue_length=$(wc -l <<< "$orderedPaymentList")
endLastPaidHeight=$(echo "$(sort -k1 ./tmp/block_ip_ch)" | (awk 'NR == 1{print $1}'))
firstLastPaidHeight=$(echo "$(sort -k1 ./tmp/block_ip_ch)"  | sed '$!d' | awk '{ print $1 }')
no_blocks_in_queue=$(( $echo $firstLastPaidHeight - $endLastPaidHeight + 1 ))	
echo "$(sort -k1 ./tmp/block_ip_ch)" | awk '{ print $_ " " ( '$endLastPaidHeight' + '$no_blocks_in_queue' + 'i++') }' > ./tmp/sorted_block_ip_ch
# содаем массив мастернод со статусом PoSeBanned (proTxHash ipPort)
ARRAY_POSEBAN_IP=()
while IFS= read -r line; do
	ARRAY_POSEBAN_IP+=( "$line" )
done <  ./tmp/poseban_ip_ch
####
# из моих (MY_MASTERNODES) мастернод, удаляем которых нет в блокчейне , новый массив (MN_FILTERED)
MN_FILTERED=($(dash-cli protx list|jq -r '.[]'|grep $(sed 's/ /\\|/g'<<<"${MY_MASTERNODES[@]}" )))
# echo ${MN_FILTERED[@]}
# опять проверяем список MY_MASTERNODES на статус PoSeBann и отсутствие в блокчейне, 
# и в конце скрипта отправляем сообщение о мастернодах со станусом "не найдена!" и "PoSeBanned!"
sorted_block_ip_ch=$(cat ./tmp/sorted_block_ip_ch)
for (( n=0; n < ${#MY_MASTERNODES[*]}; n++ ))
do  
	ip_port="" 
	m=$(( $n+1 ))
	##### попутно присваиваем моим мастернодам номер в списке.
	myMN_num=$(	echo  "${MY_MASTERNODES[n]}" | awk '{ print $_ " " ( '$n'+1 ) }')
#	echo  "${MY_MASTERNODES[n]}" | awk '{ print $_ " " ( '$n'+1 ) }' >> ./tmp/myMN_num_ch
	myMN_cutProTxHash=$(echo ${MY_MASTERNODES[$n]} | cut -c1-4 )
########	
	if echo "${MN_FILTERED[@]}"|grep -q "${MY_MASTERNODES[$n]}";then
		# Protx provided is in the protx list, so extract some facts about this masternode.
		protx_info=$(dash-cli protx info ${MY_MASTERNODES[$n]})
		collateral=$(jq -r '"\(.collateralHash)-\(.collateralIndex)"'<<<"$protx_info")
		ip_port=$(echo "$(jq -r '.state.service'<<<"$protx_info"|sed 's/:/ /g')"  | awk '{ print $1 }')
		posepenalty=$(jq -r '.state.PoSePenalty'<<<"$protx_info")
		#  Check the PoSe Score and ping the masternode
		echo | nc -z $ip_port 9999 || BODY+="does not respond to ping.\n"
		(( $posepenalty > 2045 )) && BODY+="has PoSe Score of $posepenalty.\n"
		# Now check the masternode status, first make sure it is unique
		nodes=$(dash-cli masternode list full|grep "$collateral"|grep -v ^[{}]|wc -l)
		case $nodes in
			0)
				BODY+="is MISSING from masternode list...\n"
				;;
			1)
				# Found a single MN payout address, so can check on the status.
				if dash-cli masternode list full $collateral|grep -v ^[{}]|grep -vq "ENABLED";then
					BODY+="is not in the ENABLED status...\n"
					for ((i=0; i<${#ARRAY_POSEBAN_IP[@]}; i++)); do
					  if [[ ${ARRAY_POSEBAN_IP[$i]} =~ "${MY_MASTERNODES[$n]}" ]]; then
					myMN_PoSeBanIP=$(echo "${ARRAY_POSEBAN_IP[$i]}" | awk '{ print $2 }')
					BODY+="PoSeBanned!\n" 
					  fi
					done
				fi
				;;
			*)
				BODY+="the collateral hash and index is not unique and hence cannot determine the status of this node.\n"
				;;
		esac
	else
		BODY+="Missing masternode. Check protx hash is correct.\n"
	fi
title=$(echo -e "MN$m $ip_port ProTx($myMN_cutProTxHash***)")
message=$(printf "$BODY")

if [[ -n "$BODY" ]];then
# Only send puhover if $FREQUENCY time has passed.
	if (( EPOCHSECONDS - LAST_SENT_TIME > FREQUENCY ));then
# 		BODY="Report from $(hostname)\n$BODY"
		curl -s \
		  --form-string "token=ghghghggjiwiwjknkncnmfeoi323gdq" \
		  --form-string "user=7cjwfvkvrwHBjun7xjtwJmmxjj889jH" \
		  --form-string "sound=bike" \
		  --form-string "title=$title" \
		  --form-string "message=$message" \
		https://api.pushover.net/1/messages.json &> /dev/null 
		BODY=""
		sed -i "s/\(^LAST_SENT_TIME=\).*/\1$(date +%s)/" "$PROG"
	fi
fi
BODY=""
done	

