Given "[Бб]рокер (\w+) зарегистрирован на Бирже" {
	param ($brokerName)

	Write-Host "Брокер $broker"
}

Given "(\w+) разместил заявку на (.*) (\d+) контрактов (.*) по цене (.*)" {
	param ($client, $orderType, $orderAmount, $instrument, $instrumentPrice)

	Write-Host "client = $client, orderType = $orderType, orderAmount = $orderAmount, instrument = $instrument, instrumentPrice = $instrumentPrice"
}
