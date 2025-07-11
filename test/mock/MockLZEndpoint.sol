// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FeeRouter} from "../../src/FeeRouter.sol";
import {MessagingParams, MessagingFee, MessagingReceipt, Origin} from "../../lib/LayerZero-v2/packages/layerzero-v2/evm/protocol/contracts/interfaces/ILayerZeroEndpointV2.sol";

contract MockLZEndpoint {
    event MessageSent(uint32 dstEid, bytes payload, bytes options);

    // Simple mapping to store cross-chain targets
    address public crossChainTarget;
    address public targetEndpoint; // The endpoint that should call lzReceive

    bool private _sendCalled;
    uint256 private _lastValue;
    bytes private _lastPayload;
    uint32 private _lastEid;

    function setCrossChainTarget(address target) external {
        crossChainTarget = target;
    }

    function setTargetEndpoint(address endpoint) external {
        targetEndpoint = endpoint;
    }

    // LayerZero V2 quote function
    function quote(MessagingParams calldata _params, address /*_sender*/) external pure returns (MessagingFee memory) {
        return MessagingFee({
            nativeFee: 0.001 ether, // Mock fee
            lzTokenFee: 0
        });
    }

    // LayerZero V2 send function  
    function send(MessagingParams calldata _params, address /*_refundAddress*/) external payable returns (MessagingReceipt memory) {
        _sendCalled = true;
        _lastValue = msg.value;
        _lastPayload = _params.message;
        _lastEid = _params.dstEid;

        emit MessageSent(_params.dstEid, _params.message, _params.options);

        // Simple cross-chain simulation - call the target directly
        if (crossChainTarget != address(0)) {
            // Determine source EID based on destination
            uint32 srcEid = _params.dstEid == 30101 ? uint32(30184) : uint32(30101); // ETH_EID : BASE_EID

            // We need to simulate the target endpoint calling lzReceive
            // This is a bit of a hack for testing, but it works
            MockLZEndpoint(targetEndpoint).deliverMessage{value: msg.value}(
                crossChainTarget,
                srcEid,
                _params.message,
                msg.sender
            );
        }

        return MessagingReceipt({
            guid: keccak256(abi.encodePacked(_params.dstEid, _params.message)),
            nonce: 1,
            fee: MessagingFee({nativeFee: msg.value, lzTokenFee: 0})
        });
    }

    // Legacy send function for backwards compatibility
    function sendLegacy(uint32 eid, bytes calldata payload, bytes calldata /*options*/) external payable {
        _sendCalled = true;
        _lastValue = msg.value;
        _lastPayload = payload;
        _lastEid = eid;

        emit MessageSent(eid, payload, "");

        // Simple cross-chain simulation - call the target directly
        if (crossChainTarget != address(0)) {
            // Determine source EID based on destination
            uint32 srcEid = eid == 30101 ? uint32(30184) : uint32(30101); // ETH_EID : BASE_EID

            // We need to simulate the target endpoint calling lzReceive
            // This is a bit of a hack for testing, but it works
            MockLZEndpoint(targetEndpoint).deliverMessage{value: msg.value}(
                crossChainTarget,
                srcEid,
                payload,
                msg.sender
            );
        }
    }

    // Helper function to deliver the message as if we were the endpoint
    function deliverMessage(address target, uint32 srcEid, bytes calldata payload, address sender) external payable {
        Origin memory origin = Origin({
            srcEid: srcEid,
            sender: bytes32(uint256(uint160(sender))),
            nonce: 1
        });
        FeeRouter(payable(target)).lzReceive{value: msg.value}(
            origin,
            keccak256(payload),
            payload,
            address(this),
            ""
        );
    }

    // Test helper functions
    function sendCalled() external view returns (bool) {
        return _sendCalled;
    }

    function lastValue() external view returns (uint256) {
        return _lastValue;
    }

    function lastPayload() external view returns (bytes memory) {
        return _lastPayload;
    }

    function lastEid() external view returns (uint32) {
        return _lastEid;
    }

    function reset() external {
        _sendCalled = false;
        _lastValue = 0;
        delete _lastPayload;
        _lastEid = 0;
    }

    // LayerZero V2 interface functions
    function inboundNonce(address /*_receiver*/, uint32 /*_srcEid*/, bytes32 /*_sender*/) external pure returns (uint64) {
        return 1;
    }

    function eid() external pure returns (uint32) {
        return 40245; // Base Sepolia EID
    }

    // Mock LayerZero OApp functions
    function setDelegate(address /*delegate*/) external {
        // Mock implementation - do nothing
    }
}
