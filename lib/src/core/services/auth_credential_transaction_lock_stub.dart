import 'auth_credential_transaction_lock.dart';

AuthCredentialTransactionLock createPlatformAuthCredentialTransactionLock() =>
    InProcessAuthCredentialTransactionLock();
