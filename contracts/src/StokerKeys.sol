// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title StokerKeys
/// @notice Every privileged key of Stoker on one EVM chain, named and bounded (ADR 0030, #231's story 47):
///         the Admin, one hardware wallet of the owner's, and three server keys.
///
///         - The Admin writes the Quote Registry, will hold the Guard (#247), replaces a server key, and is
///           the address the platform's share of every fee is booked to. It is handed over in two steps.
///         - The round key will post Round Roots (#247), the ladder key will raise a coin's Creator Tier and
///           never lower one (#248), and the Keeper has no privilege at all: it pays gas for calls anyone can
///           make, and is named here so the operator view reads every key from one place.
///
///         A key is replaced in two steps, so a mistyped address cannot be handed a role nobody holds: the
///         Admin proposes, and the new holder accepts. Nothing here reaches a coin's liquidity, a Credit or a
///         Creator Lock; this contract holds no funds and calls nothing.
/// @dev No owner but the Admin, no proxy, no renounce: if the Admin's device and its paper backup are both
///      lost, Listings, price writes and key replacement stop for good, and coins keep trading.
contract StokerKeys {
    /// @notice The three server keys.
    enum Role {
        RoundKey,
        LadderKey,
        Keeper
    }

    /// @notice The Admin's address.
    address public admin;
    /// @notice The address the Admin has proposed as its successor, until it accepts; zero for none.
    address public pendingAdmin;

    mapping(Role role => address) internal _holders;
    mapping(Role role => address) internal _pendingHolders;

    event AdminProposed(address indexed admin, address indexed proposed);
    event AdminHandedOver(address indexed previous, address indexed admin);
    event KeyProposed(Role indexed role, address indexed proposed);
    event KeyReplaced(Role indexed role, address indexed previous, address indexed holder);
    event KeyRevoked(Role indexed role, address indexed previous);

    error NotAdmin();
    error NotProposed();
    error ZeroAddress();

    modifier onlyAdmin() {
        _onlyAdmin();
        _;
    }

    /// @param admin_ The Admin: the owner's hardware wallet, checked by the deployment's gate (#251).
    constructor(address admin_) {
        if (admin_ == address(0)) revert ZeroAddress();
        admin = admin_;
        emit AdminHandedOver(address(0), admin_);
    }

    // ------------------------------------------------------------------ the Admin

    /// @notice Proposes the Admin's successor; it becomes the Admin only when it accepts. Proposing another
    ///         address, or the zero address, withdraws a proposal.
    // The zero address is the withdrawal of a proposal, and nobody can accept for it.
    // forge-lint: disable-next-line(missing-zero-check)
    function proposeAdmin(address proposed) external onlyAdmin {
        pendingAdmin = proposed;
        emit AdminProposed(admin, proposed);
    }

    /// @notice The proposed address takes the Admin's place. From this call on the platform's share of every
    ///         fee is booked to it; whatever was booked to the previous Admin stays owed to that address.
    ///         Every server-key proposal still waiting is voided: it was the previous Admin's choice, and a
    ///         handover may be made because that Admin's device is no longer trusted. Keys already held stay.
    function acceptAdmin() external {
        address proposed = pendingAdmin;
        if (msg.sender != proposed || proposed == address(0)) revert NotProposed();
        address previous = admin;
        admin = proposed;
        pendingAdmin = address(0);
        for (uint8 r; r <= uint8(type(Role).max); r++) {
            Role role = Role(r);
            if (_pendingHolders[role] != address(0)) {
                _pendingHolders[role] = address(0);
                emit KeyProposed(role, address(0));
            }
        }
        emit AdminHandedOver(previous, proposed);
    }

    // ------------------------------------------------------------------ the server keys

    /// @notice Proposes a new holder for a server key; the current holder keeps the role until it accepts.
    ///         Proposing the zero address withdraws a proposal.
    function proposeKey(Role role, address proposed) external onlyAdmin {
        _pendingHolders[role] = proposed;
        emit KeyProposed(role, proposed);
    }

    /// @notice The proposed address takes the role.
    function acceptKey(Role role) external {
        address proposed = _pendingHolders[role];
        if (msg.sender != proposed || proposed == address(0)) revert NotProposed();
        address previous = _holders[role];
        _holders[role] = proposed;
        _pendingHolders[role] = address(0);
        emit KeyReplaced(role, previous, proposed);
    }

    /// @notice Takes a server key away at once, from its holder and from any proposed holder: a stolen key
    ///         stops now, not when a new holder is ready. It hands the role to nobody, which is what the two
    ///         steps guard against only for a real address.
    function revokeKey(Role role) external onlyAdmin {
        address previous = _holders[role];
        _holders[role] = address(0);
        _pendingHolders[role] = address(0);
        emit KeyRevoked(role, previous);
    }

    /// @notice Who holds a server key; zero for nobody.
    function holderOf(Role role) external view returns (address) {
        return _holders[role];
    }

    /// @notice Who has been proposed for a server key and not yet accepted; zero for nobody.
    function pendingHolderOf(Role role) external view returns (address) {
        return _pendingHolders[role];
    }

    function _onlyAdmin() internal view {
        if (msg.sender != admin) revert NotAdmin();
    }
}
