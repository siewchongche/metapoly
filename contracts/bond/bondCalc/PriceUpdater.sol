// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IBond {
    function setPrice(uint) external ;
}

interface IERC20 {
    function transfer(address, uint) external;
}

contract PriceUpdater is ChainlinkClient, Ownable {
    using Chainlink for Chainlink.Request;

    address public bond;
    address private oracle;
    uint private oracleFee;
    bytes32 private jobId; 

    string url;
    string path;
    int times;


    constructor(address _oracle, bytes32 _jobId, uint _oracleFee) {
        setPublicChainlinkToken();

        oracle = _oracle;
        jobId = _jobId;
        oracleFee = _oracleFee ;      

    }

    function updateOracleParams(address _oracle, bytes32 _jobId, uint _oracleFee) external onlyOwner {
        oracle = _oracle;
        jobId = _jobId;
        oracleFee = _oracleFee ;
    }

    function updatePriceApi(address _bond, string memory _url, string memory _path, int _times) external onlyOwner {
        bond = _bond;
        url = _url;
        path = _path;
        times = _times;
    }   

    function requestPriceUpdate() external {
        require(msg.sender == bond, "not authorised");
        Chainlink.Request memory request = buildChainlinkRequest(jobId, address(this), this.fulfill.selector);

        request.add("get", url);
        request.add("path", path);

        request.addInt("times", times);

        // request.addInt("times", int(10**18));
        sendChainlinkRequestTo(oracle, request, oracleFee);
    }

    ///@dev Used by oracle to update the floor price
    function fulfill(bytes32 _requestId, uint256 _priceInETH) external recordChainlinkFulfillment(_requestId) {
        IBond(bond).setPrice(_priceInETH);
    }

    function withdrawLINK(address _to, uint _amount) external onlyOwner {
        IERC20(chainlinkTokenAddress()).transfer(_to, _amount);
    }
}