#pragma once
#include <array>
#include <string>

namespace ap::input {
using PairingKey = std::array<char, 33>;
std::string pairing_target(const std::string& device_id, const std::string& name,
                           const std::string& peer);
bool read_pairing(const std::string& target, PairingKey& key);
bool write_pairing(const std::string& target, const PairingKey& key);
} // namespace ap::input
