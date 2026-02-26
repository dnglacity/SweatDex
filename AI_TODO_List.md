Review files including .json and fix login auth issue: (attempted to login with test account with correct credentials)
AuthService.signIn error (domain: gmail.com): AuthApiException(message: Invalid login credentials,
statusCode: 400, code: invalid_credentials)
LoginScreen _handleSubmit error: AuthApiException(message: Invalid login credentials, statusCode: 400, code:
invalid_credentials)
LoginScreen _getErrorMessage raw: AuthApiException(message: Invalid login credentials, statusCode: 400, code:
invalid_credentials)

Second Issue: (attempted to create a new account)
AuthService.signUp error: AuthRetryableFetchException(message:
{"code":"unexpected_failure","message":"Database error saving new user"}, statusCode: 500)
LoginScreen _handleSubmit error: AuthRetryableFetchException(message:
{"code":"unexpected_failure","message":"Database error saving new user"}, statusCode: 500)
LoginScreen _getErrorMessage raw: AuthRetryableFetchException(message:
{"code":"unexpected_failure","message":"Database error saving new user"}, statusCode: 500)