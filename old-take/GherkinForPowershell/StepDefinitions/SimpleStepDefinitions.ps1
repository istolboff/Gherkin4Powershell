Given "[��]����� (\w+) ��������������� �� �����" {
	param ($brokerName)

	Write-Host "������ $broker"
}

Given "(\w+) ��������� ������ �� (.*) (\d+) ���������� (.*) �� ���� (.*)" {
	param ($client, $orderType, $orderAmount, $instrument, $instrumentPrice)

	Write-Host "client = $client, orderType = $orderType, orderAmount = $orderAmount, instrument = $instrument, instrumentPrice = $instrumentPrice"
}
