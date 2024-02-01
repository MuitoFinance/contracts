// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

interface IMNTHelper {
    function withdrawMnt(uint256) external;
}

contract MNTHelper {
    receive() external payable {
    }

    function withdrawMnt(address _mnt, address _to, uint256 _amount) public {
        IMNTHelper(_mnt).withdrawMnt(_amount);
        (bool success,) = _to.call{value: _amount}(new bytes(0));
        require(success, 'MNTHelper: TRANSFER MNT FAILED');
    }
}

