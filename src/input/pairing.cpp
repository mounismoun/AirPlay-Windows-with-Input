#include "input/pairing.h"
#include "input/channel.h"
#include <openssl/crypto.h>
#include <openssl/sha.h>
#include <cstring>
#ifdef _WIN32
#include <windows.h>
#include <wincred.h>
#endif

namespace ap::input {
std::string pairing_target(const std::string& device_id, const std::string& name,
                           const std::string& peer) {
    if (peer.empty()) return {};
    std::string identity;
    if (!device_id.empty()) identity = "device:" + device_id;
    else if (!name.empty()) identity = "name:" + name;
    else identity = "address:" + peer;
    unsigned char digest[SHA256_DIGEST_LENGTH];
    SHA256(reinterpret_cast<const unsigned char*>(identity.data()), identity.size(), digest);
    std::string target = "AirPlay-Windows/MacInput/";
    constexpr char hex[] = "0123456789abcdef";
    for (auto byte : digest) {
        target += hex[byte >> 4];
        target += hex[byte & 15];
    }
    return target;
}

bool read_pairing(const std::string& target, PairingKey& key) {
#ifdef _WIN32
    PCREDENTIALA entry = nullptr;
    if (target.empty() || !CredReadA(target.c_str(), CRED_TYPE_GENERIC, 0, &entry)) return false;
    bool valid = entry->CredentialBlobSize == key.size() - 1;
    if (valid) {
        std::memcpy(key.data(), entry->CredentialBlob, key.size() - 1);
        key.back() = 0;
        Secret decoded{};
        valid = decode_secret(key.data(), decoded);
        OPENSSL_cleanse(decoded.data(), decoded.size());
        if (!valid) OPENSSL_cleanse(key.data(), key.size());
    }
    if (entry->CredentialBlob) SecureZeroMemory(entry->CredentialBlob, entry->CredentialBlobSize);
    CredFree(entry);
    return valid;
#else
    return false;
#endif
}

bool write_pairing(const std::string& target, const PairingKey& key) {
#ifdef _WIN32
    if (target.empty()) return false;
    CREDENTIALA entry{};
    entry.Type = CRED_TYPE_GENERIC;
    entry.TargetName = const_cast<char*>(target.c_str());
    entry.Persist = CRED_PERSIST_LOCAL_MACHINE;
    entry.CredentialBlob = reinterpret_cast<BYTE*>(const_cast<char*>(key.data()));
    entry.CredentialBlobSize = static_cast<DWORD>(key.size() - 1);
    return CredWriteA(&entry, 0) != FALSE;
#else
    return false;
#endif
}
} // namespace ap::input
