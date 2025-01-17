// SPDX-License-Identifier: CC-BY-1.0
pragma solidity ^0.8.17;

import "./Borsh.sol";
import "./Codec.sol";
import "./Types.sol";
import "./Utils.sol";
import "openzeppelin-contracts/token/ERC20/IERC20.sol";

// Address of Cross Contract Call precompile in Aurora.
// It allows scheduling new promises to NEAR contracts.
address constant XCC_PRECOMPILE = 0x516Cded1D16af10CAd47D6D49128E2eB7d27b372;
// Address of predecessor account id precompile in Aurora.
// It allows getting the predecessor account id of the current call.
address constant PREDECESSOR_ACCOUNT_ID_PRECOMPILE = 0x723FfBAbA940e75E7BF5F6d61dCbf8d9a4De0fD7;
// Address of predecessor account id precompile in Aurora.
// It allows getting the current account id of the current call.
address constant CURRENT_ACCOUNT_ID_PRECOMPILE = 0xfeFAe79E4180Eb0284F261205E3F8CEA737afF56;
// Addresss of promise result precompile in Aurora.
address constant PROMISE_RESULT_PRECOMPILE = 0x0A3540F79BE10EF14890e87c1A0040A68Cc6AF71;
// Address of wNEAR ERC20 on mainnet
address constant wNEAR_MAINNET = 0x4861825E75ab14553E5aF711EbbE6873d369d146;

struct NEAR {
    /// Wether the represenative NEAR account id for this contract
    /// has already been created or not. This is required since the
    /// first cross contract call requires attaching extra deposit
    /// to cover storage staking balance.
    bool initialized;
    /// Address of wNEAR token contract. It is used to charge the user
    /// required tokens for paying NEAR storage fees and attached balance
    /// for cross contract calls.
    IERC20 wNEAR;
}

library AuroraSdk {
    using Codec for bytes;
    using Codec for PromiseCreateArgs;
    using Codec for PromiseWithCallback;
    using Codec for Borsh.Data;
    using Borsh for Borsh.Data;

    /// Create an instance of NEAR object. Requires the address at which
    /// wNEAR ERC20 token contract is deployed.
    function initNear(IERC20 wNEAR) public pure returns (NEAR memory) {
        return NEAR(false, wNEAR);
    }

    /// Default configuration for mainnet.
    function mainnet() public pure returns (NEAR memory) {
        return NEAR(false, IERC20(wNEAR_MAINNET));
    }

    /// Compute NEAR represtentative account for the given Aurora address.
    /// This is the NEAR account created by the cross contract call precompile.
    function nearRepresentative(address account) public returns (string memory) {
        return string(abi.encodePacked(Utils.bytesToHex(abi.encodePacked((bytes20(account)))), ".", currentAccountId()));
    }

    /// Compute implicity Aurora Address for the given NEAR account.
    function implicitAuroraAddress(string memory accountId) public pure returns (address) {
        return address(uint160(uint256(keccak256(bytes(accountId)))));
    }

    /// Compute the implicit Aurora address of the represenative NEAR account
    /// for the given Aurora address. Useful when a contract wants to call
    /// itself via a callback using cross contract call precompile.
    function nearRepresentitiveImplicitAddress(address account) public returns (address) {
        return implicitAuroraAddress(nearRepresentative(account));
    }

    /// Get the promise result at the specified index.
    function promiseResult(uint256 index) public returns (PromiseResult memory) {
        (bool success, bytes memory returnData) = CURRENT_ACCOUNT_ID_PRECOMPILE.call("");
        require(success);

        Borsh.Data memory borsh = Borsh.from(returnData);

        uint32 length = borsh.decodeU32();
        require(index < length, "Index out of bounds");

        for (uint256 i = 0; i < index; i++) {
            borsh.skipPromiseResult();
        }

        return borsh.decodePromiseResult();
    }

    /// Get the NEAR account id of the current contract. It is the account id of Aurora engine.
    function currentAccountId() public returns (string memory) {
        (bool success, bytes memory returnData) = CURRENT_ACCOUNT_ID_PRECOMPILE.call("");
        require(success);
        return string(returnData);
    }

    /// Get the NEAR account id of the predecessor contract.
    function predecessorAccountId() public returns (string memory) {
        (bool success, bytes memory returnData) = PREDECESSOR_ACCOUNT_ID_PRECOMPILE.call("");
        require(success);
        return string(returnData);
    }

    /// Crease a base promise. This is not immediately schedule for execution
    /// until transact is called. It can be combined with other promises using
    /// `then` combinator.
    ///
    /// Input is not checekd during promise creation. If it is invalid, the
    /// transaction will be scheduled either way, but it will fail during execution.
    function call(
        NEAR memory near,
        string memory targetAccountId,
        string memory method,
        bytes memory args,
        uint128 nearBalance,
        uint64 nearGas
    ) public returns (PromiseCreateArgs memory) {
        if (!near.initialized) {
            /// If the contract needs to be initialized, we need to attach
            /// 2 NEAR (= 2 * 10^24 yoctoNEAR) to the promise.
            nearBalance += 2_000_000_000_000_000_000_000_000;
            near.initialized = true;
        }

        if (nearBalance > 0) {
            near.wNEAR.transferFrom(msg.sender, address(this), uint256(nearBalance));
        }

        return PromiseCreateArgs(targetAccountId, method, args, nearBalance, nearGas);
    }

    /// Similar to `call`. It is a wrapper that simplifies the creation of a promise
    /// to a controct inside `Aurora`.
    function auroraCall(NEAR memory near, address target, bytes memory args, uint128 nearBalance, uint64 nearGas)
        public
        returns (PromiseCreateArgs memory)
    {
        return call(
            near,
            currentAccountId(),
            "call",
            abi.encodePacked(uint8(0), target, uint256(0), args.encode()),
            nearBalance,
            nearGas
        );
    }

    /// Schedule a base promise to be executed on NEAR. After this function is called
    /// the promise should not be used anymore.
    function transact(PromiseCreateArgs memory nearPromise) public {
        (bool success, bytes memory returnData) =
            XCC_PRECOMPILE.call(nearPromise.encodeCrossContractCallArgs(ExecutionMode.Eager));

        if (!success) {
            revert(string(returnData));
        }
    }

    /// Schedule a promise with callback to be executed on NEAR. After this function is called
    /// the promise should not be used anymore.
    ///
    /// Duplicated due to lack of generics in solidity. Check relevant issue:
    /// https://github.com/ethereum/solidity/issues/869
    function transact(PromiseWithCallback memory nearPromise) public {
        (bool success, bytes memory returnData) =
            XCC_PRECOMPILE.call(nearPromise.encodeCrossContractCallArgs(ExecutionMode.Eager));

        if (!success) {
            revert(string(returnData));
        }
    }

    /// Create a promise with callback from two given promises.
    function then(PromiseCreateArgs memory base, PromiseCreateArgs memory callback)
        public
        pure
        returns (PromiseWithCallback memory)
    {
        return PromiseWithCallback(base, callback);
    }
}
