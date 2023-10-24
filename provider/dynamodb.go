package provider

import (
	"encoding/json"
	"fmt"
	"strconv"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/credentials"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/dynamodb"
	"github.com/aws/aws-sdk-go/service/dynamodb/dynamodbattribute"
	pc "github.com/featureform/provider/provider_config"
	pt "github.com/featureform/provider/provider_type"
	sn "github.com/mrz1836/go-sanitize"
)

type dynamodbTableKey struct {
	Prefix, Feature, Variant string
}

func (t dynamodbTableKey) String() string {
	marshalled, _ := json.Marshal(t)
	return string(marshalled)
}

type dynamodbOnlineStore struct {
	client *dynamodb.DynamoDB
	prefix string
	BaseProvider
	timeout int
}

type dynamodbOnlineTable struct {
	client    *dynamodb.DynamoDB
	key       dynamodbTableKey
	valueType ValueType
}

type dynamodbItem struct {
	Entity string `dynamodbav:"Entity"`
	Value  string `dynamodbav:"FeatureValue"`
}

type Metadata struct {
	Tablename string `dynamodbav:"Tablename"`
	Valuetype string `dynamodbav:"ValueType"`
}

const tableCreateTimeout = 120

func dynamodbOnlineStoreFactory(serialized pc.SerializedConfig) (Provider, error) {
	dynamodbConfig := &pc.DynamodbConfig{}
	if err := dynamodbConfig.Deserialize(serialized); err != nil {
		return nil, NewProviderError(Runtime, pt.DynamoDBOnline, ConfigDeserialize, err.Error())
	}
	if dynamodbConfig.Prefix == "" {
		dynamodbConfig.Prefix = "Featureform_table__"
	}
	return NewDynamodbOnlineStore(dynamodbConfig)
}

func NewDynamodbOnlineStore(options *pc.DynamodbConfig) (*dynamodbOnlineStore, error) {
	config := &aws.Config{
		Region:      aws.String(options.Region),
		Credentials: credentials.NewStaticCredentials(options.AccessKey, options.SecretKey, ""),
	}
	sess := session.Must(session.NewSession(config))
	dynamodbClient := dynamodb.New(sess)
	if err := CreateMetadataTable(dynamodbClient); err != nil {
		return nil, NewProviderError(Connection, pt.DynamoDBOnline, ClientInitialization, err.Error())
	}
	return &dynamodbOnlineStore{dynamodbClient, options.Prefix, BaseProvider{
		ProviderType:   pt.DynamoDBOnline,
		ProviderConfig: options.Serialized(),
	}, 360,
	}, nil
}

func (store *dynamodbOnlineStore) AsOnlineStore() (OnlineStore, error) {
	return store, nil
}

func (store *dynamodbOnlineStore) Close() error {
	// dynamoDB client does not implement an equivalent to Close
	return nil
}

func CreateMetadataTable(dynamodbClient *dynamodb.DynamoDB) error {
	params := &dynamodb.CreateTableInput{
		TableName: aws.String("Metadata"),
		AttributeDefinitions: []*dynamodb.AttributeDefinition{
			{
				AttributeName: aws.String("Tablename"),
				AttributeType: aws.String("S"),
			},
		},
		KeySchema: []*dynamodb.KeySchemaElement{
			{
				AttributeName: aws.String("Tablename"),
				KeyType:       aws.String("HASH"),
			},
		},
		ProvisionedThroughput: &dynamodb.ProvisionedThroughput{
			ReadCapacityUnits:  aws.Int64(10),
			WriteCapacityUnits: aws.Int64(5),
		},
	}
	describeMetadataTableParams := &dynamodb.DescribeTableInput{
		TableName: aws.String("Metadata"),
	}
	_, err := dynamodbClient.DescribeTable(describeMetadataTableParams)
	if err != nil {
		fmt.Println("Could not describe dynamo metadata table, attemping to create...", err)
	} else {
		return nil
	}
	_, err = dynamodbClient.CreateTable(params)
	if err != nil {
		return fmt.Errorf("create attempt: %v", err)
	}
	describeTableOutput, err := dynamodbClient.DescribeTable(describeMetadataTableParams)
	if err != nil {
		return fmt.Errorf("could not check dynamo table: %v", err)
	}
	duration := 0
	for describeTableOutput == nil || *describeTableOutput.Table.TableStatus != "ACTIVE" {
		describeTableOutput, err = dynamodbClient.DescribeTable(describeMetadataTableParams)
		if err != nil {
			fmt.Println("Waiting for dynamo Metadata table to create...", err)
		}
		time.Sleep(5 * time.Second)
		duration += 5
		if duration > tableCreateTimeout {
			return fmt.Errorf("timeout creating table Metadata Table")
		}
	}
	return nil
}

func (store *dynamodbOnlineStore) UpdateMetadataTable(tablename string, valueType ValueType) error {
	input := &dynamodb.UpdateItemInput{
		ExpressionAttributeValues: map[string]*dynamodb.AttributeValue{
			":valtype": {
				S: aws.String(string(valueType.Scalar())),
			},
		},
		TableName: aws.String("Metadata"),
		Key: map[string]*dynamodb.AttributeValue{
			"Tablename": {
				S: aws.String(tablename),
			},
		},
		UpdateExpression: aws.String("set ValueType = :valtype"),
	}
	_, err := store.client.UpdateItem(input)
	return err
}

func (store *dynamodbOnlineStore) GetFromMetadataTable(tablename string) (ValueType, error) {
	input := &dynamodb.GetItemInput{
		TableName: aws.String("Metadata"),
		Key: map[string]*dynamodb.AttributeValue{
			"Tablename": {
				S: aws.String(tablename),
			},
		},
	}
	output_val, err := store.client.GetItem(input)
	if len(output_val.Item) == 0 {
		return NilType, &CustomError{"Table not found"}
	}
	if err != nil {
		return NilType, err
	}
	metadata_item := Metadata{}
	err = dynamodbattribute.UnmarshalMap(output_val.Item, &metadata_item)

	if err != nil {
		return NilType, err
	}
	return ScalarType(metadata_item.Valuetype), nil
}

func GetTablename(prefix, feature, variant string) string {
	tablename := fmt.Sprintf("%s__%s__%s", sn.Custom(prefix, "[^a-zA-Z0-9_]"), sn.Custom(feature, "[^a-zA-Z0-9_]"), sn.Custom(variant, "[^a-zA-Z0-9_]"))
	return sn.Custom(tablename, "[^a-zA-Z0-9_.\\-]")
}

func (store *dynamodbOnlineStore) GetTable(feature, variant string) (OnlineStoreTable, error) {
	key := dynamodbTableKey{store.prefix, feature, variant}
	typeOfValue, err := store.GetFromMetadataTable(GetTablename(store.prefix, feature, variant))
	if err != nil {
		return nil, &TableNotFound{feature, variant}
	}
	table := &dynamodbOnlineTable{client: store.client, key: key, valueType: typeOfValue}
	return table, nil
}

func (store *dynamodbOnlineStore) CreateTable(feature, variant string, valueType ValueType) (OnlineStoreTable, error) {
	key := dynamodbTableKey{store.prefix, feature, variant}
	_, err := store.GetFromMetadataTable(GetTablename(store.prefix, feature, variant))
	if err == nil {
		return nil, &TableAlreadyExists{feature, variant}
	}
	params := &dynamodb.CreateTableInput{
		TableName: aws.String(GetTablename(store.prefix, feature, variant)),
		AttributeDefinitions: []*dynamodb.AttributeDefinition{
			{
				AttributeName: aws.String(feature),
				AttributeType: aws.String("S"),
			},
		},
		BillingMode: aws.String("PAY_PER_REQUEST"),
		KeySchema: []*dynamodb.KeySchemaElement{
			{
				AttributeName: aws.String(feature),
				KeyType:       aws.String("HASH"),
			},
		},
	}
	err = store.UpdateMetadataTable(GetTablename(store.prefix, feature, variant), valueType)
	if err != nil {
		return nil, err
	}
	_, err = store.client.CreateTable(params)
	if err != nil {
		return nil, err
	}
	describeTableParams := &dynamodb.DescribeTableInput{TableName: aws.String(GetTablename(store.prefix, feature, variant))}
	describeTableOutput, err := store.client.DescribeTable(describeTableParams)
	if err != nil {
		return nil, err
	}
	duration := 0
	for describeTableOutput == nil || *describeTableOutput.Table.TableStatus != "ACTIVE" {
		describeTableOutput, err = store.client.DescribeTable(describeTableParams)
		if err != nil {
			return nil, err
		}
		time.Sleep(5 * time.Second)
		duration += 5
		if duration > store.timeout {
			return nil, fmt.Errorf("timeout creating table")
		}
	}
	return &dynamodbOnlineTable{store.client, key, valueType}, nil
}

func (store *dynamodbOnlineStore) DeleteTable(feature, variant string) error {
	params := &dynamodb.DeleteTableInput{
		TableName: aws.String(GetTablename(store.prefix, feature, variant)),
	}
	_, err := store.client.DeleteTable(params)
	if err != nil {
		return err
	}
	return nil
}

func (store *dynamodbOnlineStore) CheckHealth() (bool, error) {
	listOutput, err := store.client.ListTables(&dynamodb.ListTablesInput{Limit: aws.Int64(1)})
	if err != nil {
		return false, err
	}
	if len(listOutput.TableNames) == 0 {
		return false, NewProviderError(Connection, pt.DynamoDBOnline, Ping, "no tables found")
	}
	scanInput := &dynamodb.ScanInput{TableName: listOutput.TableNames[0], Limit: aws.Int64(1)}
	_, err = store.client.Scan(scanInput)
	if err != nil {
		return false, NewProviderError(Connection, pt.DynamoDBOnline, Ping, err.Error())
	}
	return true, nil
}

func (table dynamodbOnlineTable) Set(entity string, value interface{}) error {
	input := &dynamodb.UpdateItemInput{
		ExpressionAttributeValues: map[string]*dynamodb.AttributeValue{
			":val": {
				S: aws.String(fmt.Sprintf("%v", value)),
			},
		},
		TableName: aws.String(GetTablename(table.key.Prefix, table.key.Feature, table.key.Variant)),
		Key: map[string]*dynamodb.AttributeValue{
			table.key.Feature: {
				S: aws.String(entity),
			},
		},
		UpdateExpression: aws.String("set FeatureValue = :val"),
	}
	_, err := table.client.UpdateItem(input)
	return err
}

func (table dynamodbOnlineTable) Get(entity string) (interface{}, error) {
	input := &dynamodb.GetItemInput{
		TableName: aws.String(GetTablename(table.key.Prefix, table.key.Feature, table.key.Variant)),
		Key: map[string]*dynamodb.AttributeValue{
			table.key.Feature: {
				S: aws.String(entity),
			},
		},
	}
	output_val, err := table.client.GetItem(input)
	if len(output_val.Item) == 0 {
		return nil, &EntityNotFound{entity}
	}
	if err != nil {
		return nil, err
	}
	dynamodb_item := dynamodbItem{}
	err = dynamodbattribute.UnmarshalMap(output_val.Item, &dynamodb_item)
	if err != nil {
		return nil, &EntityNotFound{entity}
	}
	var result interface{}
	var result_float float64
	switch table.valueType {
	case NilType, String:
		result, err = dynamodb_item.Value, nil
	case Int:
		result, err = strconv.Atoi(dynamodb_item.Value)
	case Int64:
		result, err = strconv.ParseInt(dynamodb_item.Value, 0, 64)
	case Float32:
		result_float, err = strconv.ParseFloat(dynamodb_item.Value, 32)
		result = float32(result_float)
	case Float64:
		result, err = strconv.ParseFloat(dynamodb_item.Value, 64)
	case Bool:
		result, err = strconv.ParseBool(dynamodb_item.Value)
	}
	if err != nil {
		return nil, err
	}
	return result, nil
}
