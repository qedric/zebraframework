// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.11;
import { ERC1155 } from "@thirdweb-dev/contracts/eip/ERC1155.sol";

import "@thirdweb-dev/contracts/extension/ContractMetadata.sol";
import "@thirdweb-dev/contracts/extension/Multicall.sol";
import "@thirdweb-dev/contracts/extension/Ownable.sol";
import "@thirdweb-dev/contracts/extension/Royalty.sol";
import "@thirdweb-dev/contracts/extension/DefaultOperatorFilterer.sol";
import "@thirdweb-dev/contracts/lib/TWStrings.sol";

import "@thirdweb-dev/contracts/extension/PrimarySale.sol";
import "@thirdweb-dev/contracts/extension/PermissionsEnumerable.sol";
import "@thirdweb-dev/contracts/lib/CurrencyTransferLib.sol";
import "@thirdweb-dev/contracts/openzeppelin-presets/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "./utils.sol";
import "./piggybank.sol";

abstract contract SignaturePiggyMintERC1155 is EIP712, ISignatureMintERC1155 {
    using ECDSA for bytes32;

    bytes32 internal constant TYPEHASH =
        keccak256(
            "MintRequest(address to,uint256 quantity,uint128 validityStartTimestamp,uint128 validityEndTimestamp,string name,string description,string externalUrl,string metadata,uint256 unlockTime,uint256 targetBalance)"
        );

    constructor() EIP712("SignatureMintERC1155", "1") {}

    /// @dev Verifies that a mint request is signed by an account holding MINTER_ROLE (at the time of the function call).
    function verify(
        MintRequest calldata _req,
        bytes calldata _signature
    ) public view returns (bool success, address signer) {
        signer = _recoverAddress(_req, _signature);
        success = _canSignMintRequest(signer);
    }

    /// @dev Returns whether a given address is authorized to sign mint requests.
    function _canSignMintRequest(
        address _signer
    ) internal view virtual returns (bool);

    /// @dev Verifies a mint request
    function _processRequest(
        MintRequest calldata _req,
        bytes calldata _signature
    ) internal view returns (address signer) {
        bool success;
        (success, signer) = verify(_req, _signature);
        require(success, "Invalid request");
        require(
            _req.validityStartTimestamp <= block.timestamp &&
                block.timestamp <= _req.validityEndTimestamp,
            "Request expired"
        );
        require(_req.quantity > 0, "0 qty");
    }

    /// @dev Returns the address of the signer of the mint request.
    function _recoverAddress(
        MintRequest calldata _req,
        bytes calldata _signature
    ) internal view returns (address) {
        return
            _hashTypedDataV4(keccak256(_encodeRequest(_req))).recover(
                _signature
            );
    }

    /*
    struct MintRequest {
        address to;
        uint256 quantity;
        uint128 validityStartTimestamp;
        uint128 validityEndTimestamp;
        string name;
        string description;
        string externalUrl;
        string metadata;
        uint256 unlockTime;
        uint256 targetBalance;
    }
    */

    /// @dev Resolves 'stack too deep' error in `recoverAddress`.
    function _encodeRequest(
        MintRequest calldata _req
    ) internal pure returns (bytes memory) {
        return
            abi.encode(
                TYPEHASH,
                _req.to,
                _req.quantity,
                _req.validityStartTimestamp,
                _req.validityEndTimestamp,
                keccak256(bytes(_req.name)),
                keccak256(bytes(_req.description)),
                keccak256(bytes(_req.externalUrl)),
                keccak256(bytes(_req.metadata)),
                _req.unlockTime,
                _req.targetBalance
            );
    }
} 

contract CryptoPiggies is 
    ERC1155,
    ContractMetadata,
    Ownable,
    Royalty,
    Multicall,
    DefaultOperatorFilterer, 
    PrimarySale,
    SignaturePiggyMintERC1155,
    PermissionsEnumerable
{
    using TWStrings for uint256;

    /*//////////////////////////////////////////////////////////////
                        Events
    //////////////////////////////////////////////////////////////*/

    event ProxyDeployed(
        address deployedProxy,
        address msgSender
    );

    /*//////////////////////////////////////////////////////////////
                        State variables
    //////////////////////////////////////////////////////////////*/

    /// @dev The tokenId of the next NFT to mint.
    uint256 internal nextTokenIdToMint_;

    /// @notice This role is required to mint.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice The fee to create a new Piggy.
    uint256 private makePiggy_fee = 0.004 ether;

    /// @notice The PiggyBank implementation contract that is cloned for each new piggy
    address internal piggyBankImplementation;

    /*//////////////////////////////////////////////////////////////
                        Mappings
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice Returns the total supply of NFTs of a given tokenId
     *  @dev Mapping from tokenId => total circulating supply of NFTs of that tokenId.
     */
    mapping(uint256 => uint256) public totalSupply;

    /// @dev Stores the info for each piggy
    mapping(uint256 => IPiggyBank.Attr) internal _attributes;

    /// @dev PiggBaks are mapped to the tokenId of the NFT they are tethered to
    mapping(uint256 => address) internal _receiveAddresses;

    /*//////////////////////////////////////////////////////////////
                            Constructor
    //////////////////////////////////////////////////////////////*/
    constructor(
        string memory _name,
        string memory _symbol,
        address _royaltyRecipient,
        uint128 _royaltyBps,
        address _primarySaleRecipient,
        address _piggyBankImplementation
    ) ERC1155(_name, _symbol) {
        _setupOwner(msg.sender);
        _setupDefaultRoyaltyInfo(_royaltyRecipient, _royaltyBps);
        _setOperatorRestriction(true);
        _setupPrimarySaleRecipient(_primarySaleRecipient);
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(MINTER_ROLE, msg.sender);
        piggyBankImplementation = _piggyBankImplementation;
    }

    /*//////////////////////////////////////////////////////////////
                    Overriden metadata logic - On-chain
    //////////////////////////////////////////////////////////////*/
    function uri(uint256 tokenId) public view override returns (string memory) {
        require(totalSupply[tokenId] > 0, "Token data not found");
        return string(
            abi.encodePacked(
                "data:application/json;base64,",
                Base64.encode(
                    bytes(
                        abi.encodePacked(
                            '{"name":"',
                            _attributes[tokenId].name,
                            '","description":"',
                            _attributes[tokenId].description,
                            '","image_data":"',
                            Utils.getSvg(
                                _attributes[tokenId].name,
                                _receiveAddresses[tokenId],
                                _attributes[tokenId].targetBalance,
                                _attributes[tokenId].unlockTime
                            ),
                            '","external_url":"',
                            _attributes[tokenId].externalUrl,
                            '","attributes":[{"display_type":"date","trait_type":"Maturity Date","value":',
                            Utils.uint2str(
                                _attributes[tokenId].unlockTime
                            ),
                            '},{"trait_type":"Target Balance","value":"',
                            Utils.convertWeiToEthString(_attributes[tokenId].targetBalance),
                            ' ETH"},{"trait_type":"Receive Address","value":"',
                            Utils.toAsciiString(
                                address(_receiveAddresses[tokenId])
                            ),
                            '"}',
                            _attributes[tokenId].metadata,
                            ']}'
                        )
                    )   
                )
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                        Mint / burn logic
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice          Lets an authorized address mint NFTs to a recipient, via signed mint request
     *  @dev             - The logic in the `_canSignMintRequest` function determines whether the caller is authorized to mint NFTs.
     *
     *  @param _req      The signed mint request.
     *  @param _signature  The signature of an address with the MINTER role.
     */
    function mintWithSignature(
        MintRequest calldata _req,
        bytes calldata _signature
    ) external payable returns (address signer) {
        require(_req.quantity > 0, "Minting zero tokens.");
        require(
            block.timestamp < _req.unlockTime || _req.targetBalance > 0,
            "Unlock time should be in the future, or target balance greater than 0"
        );

        // always mint new token ids
        uint256 tokenIdToMint = nextTokenIdToMint();
        nextTokenIdToMint_ += 1;

        // Verify and process payload.
        signer = _processRequest(_req, _signature);

        // Collect price
        _collectMakePiggyFee(primarySaleRecipient());

        /*
        struct Attr {
            uint256 tokenId;
            string name;
            string description;
            string externalUrl;
            string metadata;
            uint256 unlockTime;
            uint256 targetBalance;
        }
        */
        IPiggyBank.Attr memory piglet = IPiggyBank.Attr(
            tokenIdToMint,
            _req.name,
            _req.description,
            _req.externalUrl,
            _req.metadata,
            _req.unlockTime,
            _req.targetBalance
        );
    
        // deploy a separate proxy contract to hold the token's ETH; add its address to the attributes
        _receiveAddresses[tokenIdToMint] = _deployProxyByImplementation(piglet, bytes32(tokenIdToMint));

        // Set token data
        _attributes[tokenIdToMint] = piglet;

        // Mint tokens.
        _mint(_req.to, tokenIdToMint, _req.quantity, "");

        emit TokensMintedWithSignature(signer, _req.to, tokenIdToMint);
    }

    /// @dev Every time a new token is minted, a PiggyBank proxy contract is deployed to hold the funds
    function _deployProxyByImplementation(
        IPiggyBank.Attr memory _piggyData,
        bytes32 _salt
    ) internal returns (address deployedProxy) {

        bytes32 salthash = keccak256(abi.encodePacked(msg.sender, _salt));
        deployedProxy = Clones.cloneDeterministic(
            piggyBankImplementation,
            salthash
        );

        IPiggyBank(deployedProxy).initialize(_piggyData);

        emit ProxyDeployed(deployedProxy, msg.sender);
    }

    /// @notice Lets an NFT owner withdraw their proportion of funds once the piggyBank is unlocked
    function payout(uint256 tokenId) external {
        require(totalSupply[tokenId] != 0, "Token data not found");

        uint256 thisOwnerBalance = balanceOf[msg.sender][tokenId];

        require(thisOwnerBalance != 0, "You must be an owner to withdraw!");

        (bool success, bytes memory returndata) = _receiveAddresses[tokenId].call{ value: 0 }(
            abi.encodeWithSignature(
                "payout(address, uint256, uint256)",
                msg.sender,
                thisOwnerBalance,
                totalSupply[tokenId]
            )
        );

        if (success) {
            // burn the tokens so the owner can't claim twice:
            _burn(msg.sender, tokenId, thisOwnerBalance);
        } else {
            // Look for revert reason and bubble it up if present
            if (returndata.length > 0) {
                // The easiest way to bubble the revert reason is using memory via assembly
                assembly {
                    let returndata_size := mload(returndata)
                    revert(add(32, returndata), returndata_size)
                }
            } else {
                revert("payout failed");
            }
        }
    }

    /// @notice Sets the fee for withdrawing the funds from a PiggyBank
    function setBreakPiggyBps(uint256 tokenId, uint8 bps) public onlyOwner {
        IPiggyBank(_receiveAddresses[tokenId]).setBreakPiggyBps(bps);
    }

    /*//////////////////////////////////////////////////////////////
                            ERC165 Logic
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns whether this contract supports the given interface.
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC1155, IERC165) returns (bool) {
        return
            interfaceId == 0x01ffc9a7 || // ERC165 Interface ID for ERC165
            interfaceId == 0xd9b67a26 || // ERC165 Interface ID for ERC1155
            interfaceId == 0x0e89341c || // ERC165 Interface ID for ERC1155MetadataURI
            interfaceId == type(IERC2981).interfaceId; // ERC165 ID for ERC2981
    }

    /*//////////////////////////////////////////////////////////////
                            View functions
    //////////////////////////////////////////////////////////////*/

    /// @notice The tokenId assigned to the next new NFT to be minted.
    function nextTokenIdToMint() public view virtual returns (uint256) {
        return nextTokenIdToMint_;
    }

    /*//////////////////////////////////////////////////////////////
                        ERC-1155 overrides
    //////////////////////////////////////////////////////////////*/

    /// @dev See {ERC1155-setApprovalForAll}
    function setApprovalForAll(address operator, bool approved)
        public
        override(ERC1155)
        onlyAllowedOperatorApproval(operator)
    {
        super.setApprovalForAll(operator, approved);
    }

    /**
     * @dev See {IERC1155-safeTransferFrom}.
     */
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) public override(ERC1155) onlyAllowedOperator(from) {
        super.safeTransferFrom(from, to, id, amount, data);
    }

    /**
     * @dev See {IERC1155-safeBatchTransferFrom}.
     */
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) public override(ERC1155) onlyAllowedOperator(from) {
        super.safeBatchTransferFrom(from, to, ids, amounts, data);
    }

    /*//////////////////////////////////////////////////////////////
                    Internal (overrideable) functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns whether contract metadata can be set in the given execution context.
    function _canSetContractURI() internal view virtual override returns (bool) {
        return msg.sender == owner();
    }

    /// @dev Returns whether a given address is authorized to sign mint requests.
    function _canSignMintRequest(
        address _signer
    ) internal view virtual override returns (bool) {
        return hasRole(MINTER_ROLE, _signer);
    }

    /// @dev Returns whether owner can be set in the given execution context.
    function _canSetOwner() internal view virtual override returns (bool) {
        return msg.sender == owner();
    }

    /// @dev Returns whether royalty info can be set in the given execution context.
    function _canSetRoyaltyInfo() internal view virtual override returns (bool) {
        return msg.sender == owner();
    }

    /// @dev Returns whether operator restriction can be set in the given execution context.
    function _canSetOperatorRestriction() internal virtual override returns (bool) {
        return msg.sender == owner();
    }

    /// @dev Runs before every token transfer / mint / burn.
    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal virtual override {
        super._beforeTokenTransfer(operator, from, to, ids, amounts, data);

        if (from == address(0)) {
            for (uint256 i = 0; i < ids.length; ++i) {
                totalSupply[ids[i]] += amounts[i];
            }
        }

        if (to == address(0)) {
            for (uint256 i = 0; i < ids.length; ++i) {
                totalSupply[ids[i]] -= amounts[i];
            }
        }
    }

    /// @dev Returns whether primary sale recipient can be set in the given execution context.
    function _canSetPrimarySaleRecipient()
        internal
        view
        virtual
        override
        returns (bool)
    {
        return msg.sender == owner();
    }

    /// @dev Collects and distributes the primary sale value of NFTs being claimed.
    function _collectMakePiggyFee(
        address _primarySaleRecipient
    ) internal virtual {
        if (makePiggy_fee == 0) {
            return;
        }

        require(msg.value == makePiggy_fee, "Must send the fee");
        
        address saleRecipient = _primarySaleRecipient == address(0)
            ? primarySaleRecipient()
            : _primarySaleRecipient;
        CurrencyTransferLib.transferCurrency(
            CurrencyTransferLib.NATIVE_TOKEN,
            msg.sender,
            saleRecipient,
            makePiggy_fee
        );
    }
}