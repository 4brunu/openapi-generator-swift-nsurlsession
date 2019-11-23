default_target: generate-openapi

generate-openapi:

	brew install openapi-generator

	rm -r -f openapi/OpenAPIClient/
	rm -r -f openapi/docs/
	
	openapi-generator generate \
		--input-spec openapi/openapi.yaml \
		--generator-name swift4 \
		--config openapi/openapi-config.json \
		--output openapi/ 
