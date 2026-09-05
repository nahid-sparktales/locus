// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

// Deterministic local-chain fixtures, not production assets or protocol forks.
contract FixtureERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public immutable requiresZeroFirst;
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    constructor(bool zeroFirst) { requiresZeroFirst = zeroFirst; }
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        require(!requiresZeroFirst || amount == 0 || allowance[msg.sender][spender] == 0, "zero-first");
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount); return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        _transfer(from, to, amount); return true;
    }
    function _transfer(address from, address to, uint256 amount) private {
        require(to != address(0), "recipient");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

contract FixtureERC721 {
    mapping(uint256 => address) public ownerOf;
    event Transfer(address indexed from, address indexed to, uint256 indexed id);
    function mint(address to, uint256 id) external {
        require(ownerOf[id] == address(0) && to != address(0), "mint");
        ownerOf[id] = to; emit Transfer(address(0), to, id);
    }
    function safeTransferFrom(address from, address to, uint256 id) external {
        require(msg.sender == from && ownerOf[id] == from && to != address(0), "owner");
        ownerOf[id] = to; emit Transfer(from, to, id);
        if (to.code.length != 0) {
            (bool ok, bytes memory result) = to.call(abi.encodeWithSignature(
                "onERC721Received(address,address,uint256,bytes)", msg.sender, from, id, bytes("")));
            require(ok && result.length == 32 && abi.decode(result, (bytes4)) == 0x150b7a02, "receiver");
        }
    }
}

contract FixtureERC1155 {
    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 amount);
    function mint(address to, uint256 id) external {
        require(to != address(0), "recipient");
        balanceOf[to][id] += 1; emit TransferSingle(msg.sender, address(0), to, id, 1);
    }
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external {
        require(msg.sender == from && to != address(0) && amount == 1 && data.length == 0, "subset");
        balanceOf[from][id] -= amount; balanceOf[to][id] += amount;
        emit TransferSingle(msg.sender, from, to, id, amount);
        if (to.code.length != 0) {
            (bool ok, bytes memory result) = to.call(abi.encodeWithSignature(
                "onERC1155Received(address,address,uint256,uint256,bytes)", msg.sender, from, id, amount, data));
            require(ok && result.length == 32 && abi.decode(result, (bytes4)) == 0xf23a6e61, "receiver");
        }
    }
}
