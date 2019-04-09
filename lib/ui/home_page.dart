import 'dart:async';
import 'package:flare_flutter/flare.dart';
import 'package:flare_dart/math/mat2d.dart';
import 'package:flare_flutter/flare_actor.dart';
import 'package:flare_flutter/flare_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:event_taxi/event_taxi.dart';
import 'package:logging/logging.dart';
import 'package:kalium_wallet_flutter/ui/widgets/auto_resize_text.dart';
import 'package:kalium_wallet_flutter/appstate_container.dart';
import 'package:kalium_wallet_flutter/themes.dart';
import 'package:kalium_wallet_flutter/dimens.dart';
import 'package:kalium_wallet_flutter/localization.dart';
import 'package:kalium_wallet_flutter/model/address.dart';
import 'package:kalium_wallet_flutter/model/list_model.dart';
import 'package:kalium_wallet_flutter/model/db/account.dart';
import 'package:kalium_wallet_flutter/model/db/contact.dart';
import 'package:kalium_wallet_flutter/model/db/appdb.dart';
import 'package:kalium_wallet_flutter/network/model/block_types.dart';
import 'package:kalium_wallet_flutter/network/model/response/account_history_response_item.dart';
import 'package:kalium_wallet_flutter/styles.dart';
import 'package:kalium_wallet_flutter/app_icons.dart';
import 'package:kalium_wallet_flutter/ui/contacts/add_contact.dart';
import 'package:kalium_wallet_flutter/ui/send/send_sheet.dart';
import 'package:kalium_wallet_flutter/ui/send/send_confirm_sheet.dart';
import 'package:kalium_wallet_flutter/ui/send/send_complete_sheet.dart';
import 'package:kalium_wallet_flutter/ui/receive/receive_sheet.dart';
import 'package:kalium_wallet_flutter/ui/settings/settings_drawer.dart';
import 'package:kalium_wallet_flutter/ui/widgets/buttons.dart';
import 'package:kalium_wallet_flutter/ui/widgets/app_drawer.dart';
import 'package:kalium_wallet_flutter/ui/widgets/app_scaffold.dart';
import 'package:kalium_wallet_flutter/ui/widgets/sheets.dart';
import 'package:kalium_wallet_flutter/ui/widgets/list_slidable.dart';
import 'package:kalium_wallet_flutter/ui/util/routes.dart';
import 'package:kalium_wallet_flutter/ui/widgets/reactive_refresh.dart';
import 'package:kalium_wallet_flutter/ui/util/ui_util.dart';
import 'package:kalium_wallet_flutter/util/sharedprefsutil.dart';
import 'package:kalium_wallet_flutter/util/numberutil.dart';
import 'package:kalium_wallet_flutter/util/fileutil.dart';
import 'package:kalium_wallet_flutter/util/hapticutil.dart';
import 'package:kalium_wallet_flutter/util/caseconverter.dart';
import 'package:qr/qr.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:kalium_wallet_flutter/bus/events.dart';

class AppHomePage extends StatefulWidget {
  @override
  _AppHomePageState createState() => _AppHomePageState();
}

class _AppHomePageState extends State<AppHomePage>
    with
        WidgetsBindingObserver,
        SingleTickerProviderStateMixin,
        FlareController {
  final GlobalKey<AppScaffoldState> _scaffoldKey =
      new GlobalKey<AppScaffoldState>();
  final Logger log = Logger("HomePage");

  // Controller for placeholder card animations
  AnimationController _placeholderCardAnimationController;
  Animation<double> _opacityAnimation;
  bool _animationDisposed;

  // Receive card instance
  AppReceiveSheet receive;

  // A separate unfortunate instance of this list, is a little unfortunate
  // but seems the only way to handle the animations
  final Map<String, GlobalKey<AnimatedListState>> _listKeyMap = Map();
  final Map<String, ListModel<AccountHistoryResponseItem>> _historyListMap = Map();

  // monKey widget
  Widget _monKey;
  Widget _largeMonkey;
  bool _monkeyOverlayOpen = false;
  bool _monkeyDownloadTriggered = false;
  // List of contacts (Store it so we only have to query the DB once for transaction cards)
  List<Contact> _contacts = List();

  DBHelper dbHelper;

  // Price conversion state (BTC, NANO, NONE)
  PriceConversion _priceConversion;
  bool _pricesHidden = false;

  bool _isRefreshing = false;

  bool _lockDisabled = false; // whether we should avoid locking the app

  // FCM instance
  final FirebaseMessaging _firebaseMessaging = FirebaseMessaging();

  // Animation for swiping to send
  ActorAnimation _sendSlideAnimation;
  ActorAnimation _sendSlideReleaseAnimation;
  double _fanimationPosition;
  bool releaseAnimation = false;

  void initialize(FlutterActorArtboard actor) {
    _fanimationPosition = 0.0;
    _sendSlideAnimation = actor.getAnimation("pull");
    _sendSlideReleaseAnimation = actor.getAnimation("release");
  }

  void setViewTransform(Mat2D viewTransform) {}

  bool advance(FlutterActorArtboard artboard, double elapsed) {
    if (releaseAnimation) {
      _sendSlideReleaseAnimation.apply(
          _sendSlideReleaseAnimation.duration * (1 - _fanimationPosition),
          artboard,
          1.0);
    } else {
      _sendSlideAnimation.apply(
          _sendSlideAnimation.duration * _fanimationPosition, artboard, 1.0);
    }
    return true;
  }

  /// Notification includes which account its for, automatically switch to it if they're entering app from notification
  Future<void> _chooseCorrectAccountFromNotification(
      Map<String, dynamic> message) async {
    try {
      if (message.containsKey("account")) {
        Account selectedAccount = await dbHelper.getSelectedAccount();
        if (message['account'] != selectedAccount.address) {
          List<Account> accounts = await dbHelper.getAccounts();
          for (int i = 0; i < accounts.length; i++) {
            if (accounts[i].address == message['account']) {
              await dbHelper.changeAccount(accounts[i]);
              EventTaxiImpl.singleton()
                  .fire(AccountChangedEvent(account: accounts[i]));
              break;
            }
          }
        }
      }
    } catch (e) {
      log.severe(e.toString());
    }
  }

  @override
  void initState() {
    super.initState();
    this.dbHelper = DBHelper();
    _registerBus();
    WidgetsBinding.instance.addObserver(this);
    SharedPrefsUtil.inst.getPriceConversion().then((result) {
      _priceConversion = result;
    });
    _addSampleContact();
    _updateContacts();
    _monkeyDownloadTriggered = false;
    // Setup placeholder animation and start
    _animationDisposed = false;
    _placeholderCardAnimationController = new AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _placeholderCardAnimationController
        .addListener(_animationControllerListener);
    _opacityAnimation = new Tween(begin: 1.0, end: 0.4).animate(
      CurvedAnimation(
        parent: _placeholderCardAnimationController,
        curve: Curves.easeIn,
        reverseCurve: Curves.easeOut,
      ),
    );
    _opacityAnimation.addStatusListener(_animationStatusListener);
    _placeholderCardAnimationController.forward();
    // Register push notifications
    _firebaseMessaging.configure(
      onMessage: (Map<String, dynamic> message) async {
        print("onMessage: $message");
      },
      onLaunch: (Map<String, dynamic> message) async {
        _chooseCorrectAccountFromNotification(message);
      },
      onResume: (Map<String, dynamic> message) async {
        _chooseCorrectAccountFromNotification(message);
      },
    );
    _firebaseMessaging.requestNotificationPermissions(
        const IosNotificationSettings(sound: true, badge: true, alert: true));
    _firebaseMessaging.onIosSettingsRegistered
        .listen((IosNotificationSettings settings) {
      if (settings.alert || settings.badge || settings.sound) {
        SharedPrefsUtil.inst.getNotificationsSet().then((beenSet) {
          if (!beenSet) {
            SharedPrefsUtil.inst.setNotificationsOn(true);
          }
        });
        _firebaseMessaging.getToken().then((String token) {
          if (token != null) {
            EventTaxiImpl.singleton().fire(FcmUpdateEvent(token: token));
          }
        });
      } else {
        SharedPrefsUtil.inst.setNotificationsOn(false).then((_) {
          _firebaseMessaging.getToken().then((String token) {
            EventTaxiImpl.singleton().fire(FcmUpdateEvent(token: token));
          });
        });
      }
    });
    _firebaseMessaging.getToken().then((String token) {
      if (token != null) {
        EventTaxiImpl.singleton().fire(FcmUpdateEvent(token: token));
      }
    });
  }

  void _animationStatusListener(AnimationStatus status) {
    switch (status) {
      case AnimationStatus.dismissed:
        _placeholderCardAnimationController.forward();
        break;
      case AnimationStatus.completed:
        _placeholderCardAnimationController.reverse();
        break;
      default:
        return null;
    }
  }

  void _animationControllerListener() {
    setState(() {});
  }

  void _startAnimation() {
    if (_animationDisposed) {
      _animationDisposed = false;
      _placeholderCardAnimationController
          .addListener(_animationControllerListener);
      _opacityAnimation.addStatusListener(_animationStatusListener);
      _placeholderCardAnimationController.forward();
    }
  }

  void _disposeAnimation() {
    if (!_animationDisposed) {
      _animationDisposed = true;
      _opacityAnimation.removeStatusListener(_animationStatusListener);
      _placeholderCardAnimationController
          .removeListener(_animationControllerListener);
      _placeholderCardAnimationController.stop();
    }
  }

  /// Add donations contact if it hasnt already been added
  Future<void> _addSampleContact() async {
    bool contactAdded = await SharedPrefsUtil.inst.getFirstContactAdded();
    if (!contactAdded) {
      bool addressExists = await dbHelper.contactExistsWithAddress(
          "ban_1ka1ium4pfue3uxtntqsrib8mumxgazsjf58gidh1xeo5te3whsq8z476goo");
      if (addressExists) {
        return;
      }
      bool nameExists =
          await dbHelper.contactExistsWithName("@KaliumDonations");
      if (nameExists) {
        return;
      }
      await SharedPrefsUtil.inst.setFirstContactAdded(true);
      Contact c = Contact(
          name: "@KaliumDonations",
          address:
              "ban_1ka1ium4pfue3uxtntqsrib8mumxgazsjf58gidh1xeo5te3whsq8z476goo");
      await dbHelper.saveContact(c);
    }
  }

  void _updateContacts() {
    dbHelper.getContacts().then((contacts) {
      setState(() {
        _contacts = contacts;
      });
    });
  }

  StreamSubscription<HistoryHomeEvent> _historySub;
  StreamSubscription<ContactModifiedEvent> _contactModifiedSub;
  StreamSubscription<SendCompleteEvent> _sendCompleteSub;
  StreamSubscription<DisableLockTimeoutEvent> _disableLockSub;
  StreamSubscription<MonkeyOverlayClosedEvent> _monkeyOverlaySub;
  StreamSubscription<AccountChangedEvent> _switchAccountSub;

  void _registerBus() {
    _historySub = EventTaxiImpl.singleton()
        .registerTo<HistoryHomeEvent>()
        .listen((event) {
      diffAndUpdateHistoryList(event.items);
      setState(() {
        _isRefreshing = false;
      });
      if (StateContainer.of(context).initialDeepLink != null) {
        handleDeepLink(StateContainer.of(context).initialDeepLink);
        StateContainer.of(context).initialDeepLink = null;
      }
    });
    _sendCompleteSub = EventTaxiImpl.singleton()
        .registerTo<SendCompleteEvent>()
        .listen((event) {
      // Route to send complete if received process response for send block
      if (event.previous != null) {
        // Route to send complete
        dbHelper.getContactWithAddress(event.previous.link).then((contact) {
          String contactName = contact == null ? null : contact.name;
          Navigator.of(context).popUntil(RouteUtils.withNameLike('/home'));
          AppSendCompleteSheet(event.previous.sendAmount, event.previous.link, contactName,
                  localAmount: event.previous.localCurrencyValue)
              .mainBottomSheet(context);
        });
      }
    });
    _contactModifiedSub = EventTaxiImpl.singleton()
        .registerTo<ContactModifiedEvent>()
        .listen((event) {
      _updateContacts();
    });
    _monkeyOverlaySub = EventTaxiImpl.singleton()
        .registerTo<MonkeyOverlayClosedEvent>()
        .listen((event) {
      Future.delayed(Duration(milliseconds: 150), () {
        setState(() {
          _monkeyOverlayOpen = false;
        });
      });
    });
    // Hackish event to block auto-lock functionality
    _disableLockSub = EventTaxiImpl.singleton()
        .registerTo<DisableLockTimeoutEvent>()
        .listen((event) {
      if (event.disable) {
        cancelLockEvent();
      }
      _lockDisabled = event.disable;
    });
    // User changed account
    _switchAccountSub = EventTaxiImpl.singleton()
        .registerTo<AccountChangedEvent>()
        .listen((event) {
      setState(() {
        _monKey = null;
        _largeMonkey = null;
        StateContainer.of(context).wallet.loading = true;
        StateContainer.of(context).wallet.historyLoading = true;
        _startAnimation();
        StateContainer.of(context).updateWallet(account: event.account);
      });
      UIUtil.downloadOrRetrieveMonkey(context,
              event.account.address, MonkeySize.HOME_SMALL)
          .then((result) {
        if (result != null) {
          FileUtil.pngHasValidSignature(result).then((valid) {
            if (valid) {
              setState(() {
                _monKey = Image.file(result);
              });
            }
          });
        }
      });
      UIUtil.downloadOrRetrieveMonkey(context,
              event.account.address, MonkeySize.LARGE)
          .then((result) {
        if (result != null) {
          FileUtil.pngHasValidSignature(result).then((valid) {
            if (valid) {
              setState(() {
                _largeMonkey = Image.file(result);
              });
            }
          });
        }
      });
      paintQrCode(address: event.account.address);
      if (event.delayPop) {
        Future.delayed(Duration(milliseconds: 300), () {
          Navigator.of(context).popUntil(RouteUtils.withNameLike("/home"));
        });
      } else if (!event.noPop) {
        Navigator.of(context).popUntil(RouteUtils.withNameLike("/home"));
      }
    });
  }

  @override
  void dispose() {
    _destroyBus();
    WidgetsBinding.instance.removeObserver(this);
    _placeholderCardAnimationController.dispose();
    super.dispose();
  }

  void _destroyBus() {
    if (_historySub != null) {
      _historySub.cancel();
    }
    if (_contactModifiedSub != null) {
      _contactModifiedSub.cancel();
    }
    if (_sendCompleteSub != null) {
      _sendCompleteSub.cancel();
    }
    if (_disableLockSub != null) {
      _disableLockSub.cancel();
    }
    if (_monkeyOverlaySub != null) {
      _monkeyOverlaySub.cancel();
    }
    if (_switchAccountSub != null) {
      _switchAccountSub.cancel();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Handle websocket connection when app is in background
    // terminate it to be eco-friendly
    switch (state) {
      case AppLifecycleState.paused:
        setAppLockEvent();
        StateContainer.of(context).disconnect();
        super.didChangeAppLifecycleState(state);
        break;
      case AppLifecycleState.resumed:
        cancelLockEvent();
        StateContainer.of(context).reconnect();
        if (!StateContainer.of(context).wallet.loading && StateContainer.of(context).initialDeepLink != null) {
          handleDeepLink(StateContainer.of(context).initialDeepLink);
          StateContainer.of(context).initialDeepLink = null;
        }
        super.didChangeAppLifecycleState(state);
        break;
      default:
        super.didChangeAppLifecycleState(state);
        break;
    }
  }

  // To lock and unlock the app
  StreamSubscription<dynamic> lockStreamListener;

  Future<void> setAppLockEvent() async {
    if (await SharedPrefsUtil.inst.getLock() && !_lockDisabled) {
      if (lockStreamListener != null) {
        lockStreamListener.cancel();
      }
      Future<dynamic> delayed = new Future.delayed(
          (await SharedPrefsUtil.inst.getLockTimeout()).getDuration());
      delayed.then((_) {
        return true;
      });
      lockStreamListener = delayed.asStream().listen((_) {
        Navigator.of(context).pushReplacementNamed('/');
      });
    }
  }

  Future<void> cancelLockEvent() async {
    if (lockStreamListener != null) {
      lockStreamListener.cancel();
    }
  }

  // Used to build list items that haven't been removed.
  Widget _buildItem(
      BuildContext context, int index, Animation<double> animation) {
    String displayName = smallScreen(context)
        ? _historyListMap[StateContainer.of(context).wallet.address][index].getShorterString()
        : _historyListMap[StateContainer.of(context).wallet.address][index].getShortString();
    _contacts.forEach((contact) {
      if (contact.address == _historyListMap[StateContainer.of(context).wallet.address][index].account) {
        displayName = contact.name;
      }
    });
    return _buildTransactionCard(
        _historyListMap[StateContainer.of(context).wallet.address][index], animation, displayName, context);
  }

  // Return widget for list
  Widget _getListWidget(BuildContext context) {
    if (StateContainer.of(context).wallet.historyLoading) {
      // Loading Animation
      return ReactiveRefreshIndicator(
          backgroundColor: StateContainer.of(context).curTheme.backgroundDark,
          onRefresh: _refresh,
          isRefreshing: _isRefreshing,
          child: ListView(
            padding: EdgeInsets.fromLTRB(0, 5.0, 0, 15.0),
            children: <Widget>[
              _buildLoadingTransactionCard(
                  "Sent", "10244000", "123456789121234", context),
              _buildLoadingTransactionCard(
                  "Received", "100,00000", "@bbedwards1234", context),
              _buildLoadingTransactionCard(
                  "Sent", "14500000", "12345678912345671234", context),
              _buildLoadingTransactionCard(
                  "Sent", "12,51200", "123456789121234", context),
              _buildLoadingTransactionCard(
                  "Received", "1,45300", "123456789121234", context),
              _buildLoadingTransactionCard(
                  "Sent", "100,00000", "12345678912345671234", context),
              _buildLoadingTransactionCard(
                  "Received", "24,00000", "12345678912345671234", context),
              _buildLoadingTransactionCard(
                  "Sent", "1,00000", "123456789121234", context),
            ],
          ));
    } else if (StateContainer.of(context).wallet.history.length == 0) {
      _disposeAnimation();
      return ReactiveRefreshIndicator(
        backgroundColor: StateContainer.of(context).curTheme.backgroundDark,
        child: ListView(
          padding: EdgeInsets.fromLTRB(0, 5.0, 0, 15.0),
          children: <Widget>[
            _buildWelcomeTransactionCard(context),
            _buildDummyTransactionCard(
                AppLocalization.of(context).sent,
                AppLocalization.of(context).exampleCardLittle,
                AppLocalization.of(context).exampleCardTo,
                context),
            _buildDummyTransactionCard(
                AppLocalization.of(context).received,
                AppLocalization.of(context).exampleCardLot,
                AppLocalization.of(context).exampleCardFrom,
                context),
          ],
        ),
        onRefresh: _refresh,
        isRefreshing: _isRefreshing,
      );
    } else {
      _disposeAnimation();
    }
    // Setup history list
    if (!_listKeyMap.containsKey(StateContainer.of(context).wallet.address)) {
      _listKeyMap.putIfAbsent(StateContainer.of(context).wallet.address, () => GlobalKey<AnimatedListState>());
      setState(() {
        _historyListMap.putIfAbsent(
          StateContainer.of(context).wallet.address,
          () => ListModel<AccountHistoryResponseItem>(
                listKey: _listKeyMap[StateContainer.of(context).wallet.address],
                initialItems: StateContainer.of(context).wallet.history,
                )
        );
      });
    }
    return ReactiveRefreshIndicator(
      backgroundColor: StateContainer.of(context).curTheme.backgroundDark,
      child: AnimatedList(
        key: _listKeyMap[StateContainer.of(context).wallet.address],
        padding: EdgeInsets.fromLTRB(0, 5.0, 0, 15.0),
        initialItemCount: _historyListMap[StateContainer.of(context).wallet.address].length,
        itemBuilder: _buildItem,
      ),
      onRefresh: _refresh,
      isRefreshing: _isRefreshing,
    );
  }

  // Refresh list
  Future<void> _refresh() async {
    setState(() {
      _isRefreshing = true;
    });
    HapticUtil.success();
    StateContainer.of(context).requestUpdate();
    // Hide refresh indicator after 3 seconds if no server response
    Future.delayed(new Duration(seconds: 3), () {
      setState(() {
        _isRefreshing = false;
      });
    });
  }

  ///
  /// Because there's nothing convenient like DiffUtil, some manual logic
  /// to determine the differences between two lists and to add new items.
  ///
  /// Depends on == being overriden in the AccountHistoryResponseItem class
  ///
  /// Required to do it this way for the animation
  ///
  void diffAndUpdateHistoryList(List<AccountHistoryResponseItem> newList) {
    if (newList == null || newList.length == 0 || _historyListMap[StateContainer.of(context).wallet.address] == null) return;
    // Get items not in current list, and add them from top-down
    newList.reversed
        .where((item) => !_historyListMap[StateContainer.of(context).wallet.address].items.contains(item))
        .forEach((historyItem) {
      setState(() {
        _historyListMap[StateContainer.of(context).wallet.address].insertAtTop(historyItem);
      });
    });
  }

  void handleDeepLink(link) {
    Address address = Address(link);
    if (!address.isValid()) {
      return;
    }
    String amount;
    String contactName;
    if (address.amount != null) {
      // Require minimum 1 BANOSHI to send
      if (BigInt.parse(address.amount) >= BigInt.from(10).pow(27)) {
        amount = address.amount;
      }
    }
    // See if a contact
    dbHelper.getContactWithAddress(address.address).then((contact) {
      if (contact != null) {
        contactName = contact.name;
      }
      // Remove any other screens from stack
      Navigator.of(context).popUntil(RouteUtils.withNameLike('/home'));
      if (amount != null) {
        // Go to send confirm with amount
        AppSendConfirmSheet(amount, address.address, contactName: contactName)
            .mainBottomSheet(context);
      } else {
        // Go to send with address
        AppSendSheet(contact: contact, address: address.address)
            .mainBottomSheet(context);
      }
    });
  }

  void paintQrCode({String address}) {
    QrPainter painter = QrPainter(
      data: address == null ? StateContainer.of(context).wallet.address : address,
      version: 6,
      errorCorrectionLevel: QrErrorCorrectLevel.Q,
    );
    painter.toImageData(MediaQuery.of(context).size.width).then((byteData) {
      setState(() {
        receive = AppReceiveSheet(
          Container(
              width: MediaQuery.of(context).size.width / 2.675,
              child: Image.memory(byteData.buffer.asUint8List())),
        );
      });
    });    
  }

  @override
  Widget build(BuildContext context) {
    // Create QR ahead of time because it improves performance this way
    if (receive == null) {
      paintQrCode();
    }

    // Download/Retrieve smaller and large monKeys
    if (!_monkeyDownloadTriggered) {
      _monkeyDownloadTriggered = true;
      UIUtil.downloadOrRetrieveMonkey(context,
              StateContainer.of(context).wallet.address, MonkeySize.HOME_SMALL)
          .then((result) {
        if (result != null) {
          FileUtil.pngHasValidSignature(result).then((valid) {
            if (valid) {
              setState(() {
                _monKey = Image.file(result);
              });
            }
          });
        }
      });
      UIUtil.downloadOrRetrieveMonkey(context,
              StateContainer.of(context).wallet.address, MonkeySize.LARGE)
          .then((result) {
        if (result != null) {
          FileUtil.pngHasValidSignature(result).then((valid) {
            if (valid) {
              setState(() {
                _largeMonkey = Image.file(result);
              });
            }
          });
        }
      });
    }
    return AppScaffold(
      resizeToAvoidBottomPadding: false,
      key: _scaffoldKey,
      backgroundColor: StateContainer.of(context).curTheme.background,
      drawer: SizedBox(
        width: UIUtil.drawerWidth(context),
        child: AppDrawer(
          child: SettingsSheet(),
        ),
      ),
      body: SafeArea(
        minimum: EdgeInsets.only(
            top: MediaQuery.of(context).size.height * 0.045,
            bottom: MediaQuery.of(context).size.height * 0.035),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            //Main Card
            _buildMainCard(context, _scaffoldKey),
            //Main Card End

            //Transactions Text
            Container(
              margin: EdgeInsets.fromLTRB(30.0, 20.0, 26.0, 0.0),
              child: Row(
                children: <Widget>[
                  Text(
                    CaseChange.toUpperCase(
                        AppLocalization.of(context).transactions, context),
                    textAlign: TextAlign.left,
                    style: TextStyle(
                      fontSize: 14.0,
                      fontWeight: FontWeight.w100,
                      color: StateContainer.of(context).curTheme.text,
                    ),
                  ),
                ],
              ),
            ), //Transactions Text End

            //Transactions List
            Expanded(
              child: Stack(
                children: <Widget>[
                  _getListWidget(context),
                  //List Top Gradient End
                  Align(
                    alignment: Alignment.topCenter,
                    child: Container(
                      height: 10.0,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            StateContainer.of(context).curTheme.background00,
                            StateContainer.of(context).curTheme.background
                          ],
                          begin: Alignment(0.5, 1.0),
                          end: Alignment(0.5, -1.0),
                        ),
                      ),
                    ),
                  ), // List Top Gradient End

                  //List Bottom Gradient
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      height: 30.0,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            StateContainer.of(context).curTheme.background00,
                            StateContainer.of(context).curTheme.background
                          ],
                          begin: Alignment(0.5, -1),
                          end: Alignment(0.5, 0.5),
                        ),
                      ),
                    ),
                  ), //List Bottom Gradient End
                ],
              ),
            ), //Transactions List End

            //Buttons Area
            Container(
              color: StateContainer.of(context).curTheme.background,
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(100),
                        boxShadow: [
                          StateContainer.of(context).curTheme.boxShadowButton
                        ],
                      ),
                      height: 55,
                      margin: EdgeInsets.only(left: 14, top: 0.0, right: 7.0),
                      child: FlatButton(
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(100.0)),
                        color: receive != null
                            ? StateContainer.of(context).curTheme.primary
                            : StateContainer.of(context).curTheme.primary60,
                        child: AutoSizeText(
                          AppLocalization.of(context).receive,
                          textAlign: TextAlign.center,
                          style: AppStyles.textStyleButtonPrimary(context),
                          maxLines: 1,
                          stepGranularity: 0.5,
                        ),
                        onPressed: () {
                          if (receive == null) {
                            return;
                          }
                          receive.mainBottomSheet(context);
                        },
                        highlightColor: receive != null
                            ? StateContainer.of(context).curTheme.background40
                            : Colors.transparent,
                        splashColor: receive != null
                            ? StateContainer.of(context).curTheme.background40
                            : Colors.transparent,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(100),
                        boxShadow: [
                          StateContainer.of(context).curTheme.boxShadowButton
                        ],
                      ),
                      height: 55,
                      margin: EdgeInsets.only(left: 7, top: 0.0, right: 14.0),
                      child: FlatButton(
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(100.0)),
                        color:
                            StateContainer.of(context).wallet.accountBalance >
                                    BigInt.zero
                                ? StateContainer.of(context).curTheme.primary
                                : StateContainer.of(context).curTheme.primary60,
                        child: AutoSizeText(
                          AppLocalization.of(context).send,
                          textAlign: TextAlign.center,
                          style: AppStyles.textStyleButtonPrimary(context),
                          maxLines: 1,
                          stepGranularity: 0.5,
                        ),
                        onPressed: () {
                          if (StateContainer.of(context).wallet.accountBalance >
                              BigInt.zero) {
                            AppSendSheet().mainBottomSheet(context);
                          }
                        },
                        highlightColor: StateContainer.of(context)
                                    .wallet
                                    .accountBalance >
                                BigInt.zero
                            ? StateContainer.of(context).curTheme.background40
                            : Colors.transparent,
                        splashColor: StateContainer.of(context)
                                    .wallet
                                    .accountBalance >
                                BigInt.zero
                            ? StateContainer.of(context).curTheme.background40
                            : Colors.transparent,
                      ),
                    ),
                  ),
                ],
              ),
            ), //Buttons Area End
          ],
        ),
      ),
    );
  }

  // Transaction Card/List Item
  Widget _buildTransactionCard(AccountHistoryResponseItem item,
      Animation<double> animation, String displayName, BuildContext context) {
    TransactionDetailsSheet transactionDetails =
        TransactionDetailsSheet(item.hash, item.account, displayName);
    String text;
    IconData icon;
    Color iconColor;
    if (item.type == BlockTypes.SEND) {
      text = AppLocalization.of(context).sent;
      icon = AppIcons.sent;
      iconColor = StateContainer.of(context).curTheme.text60;
    } else {
      text = AppLocalization.of(context).received;
      icon = AppIcons.received;
      iconColor = StateContainer.of(context).curTheme.primary60;
    }
    return Slidable(
      delegate: SlidableScrollDelegate(),
      actionExtentRatio: 0.35,
      movementDuration: Duration(milliseconds: 300),
      enabled: StateContainer.of(context).wallet.accountBalance > BigInt.zero,
      onTriggered: (preempt) {
        if (preempt) {
          setState(() {
            releaseAnimation = true;
          });
        } else {
          // See if a contact
          dbHelper.getContactWithAddress(item.account).then((contact) {
            // Go to send with address
            AppSendSheet(
                    contact: contact,
                    address: item.account,
                    quickSendAmount: item.amount)
                .mainBottomSheet(context);
          });
        }
      },
      onAnimationChanged: (animation) {
        if (animation != null) {
          _fanimationPosition = animation.value;
          if (animation.value == 0.0 && releaseAnimation) {
            setState(() {
              releaseAnimation = false;
            });
          }
        }
      },
      secondaryActions: <Widget>[
        SlideAction(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.transparent,
            ),
            margin: EdgeInsets.only(
                right: MediaQuery.of(context).size.width * 0.15,
                top: 4,
                bottom: 4),
            child: Container(
              alignment: Alignment(-0.5, 0),
              constraints: BoxConstraints.expand(),
              child: FlareActor("assets/pulltosend_animation.flr",
                  animation: "pull",
                  fit: BoxFit.contain,
                  controller: this,
                  color: StateContainer.of(context).curTheme.primary),
            ),
          ),
        ),
      ],
      child: _SizeTransitionNoClip(
        sizeFactor: animation,
        child: Container(
          margin: EdgeInsets.fromLTRB(14.0, 4.0, 14.0, 4.0),
          decoration: BoxDecoration(
            color: StateContainer.of(context).curTheme.backgroundDark,
            borderRadius: BorderRadius.circular(10.0),
            boxShadow: [StateContainer.of(context).curTheme.boxShadow],
          ),
          child: FlatButton(
            highlightColor: StateContainer.of(context).curTheme.text15,
            splashColor: StateContainer.of(context).curTheme.text15,
            color: StateContainer.of(context).curTheme.backgroundDark,
            padding: EdgeInsets.all(0.0),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10.0)),
            onPressed: () => transactionDetails.mainBottomSheet(context),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    vertical: 14.0, horizontal: 20.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Container(
                            margin: EdgeInsets.only(right: 16.0),
                            child: Icon(icon, color: iconColor, size: 20)),
                        Container(
                          width: MediaQuery.of(context).size.width / 4,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                text,
                                textAlign: TextAlign.left,
                                style:
                                    AppStyles.textStyleTransactionType(context),
                              ),
                              RichText(
                                textAlign: TextAlign.left,
                                text: TextSpan(
                                  text: '',
                                  children: [
                                    TextSpan(
                                      text: item.getFormattedAmount(),
                                      style:
                                          AppStyles.textStyleTransactionAmount(
                                              context),
                                    ),
                                    TextSpan(
                                      text: " BAN",
                                      style: AppStyles.textStyleTransactionUnit(
                                          context),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    Container(
                      width: MediaQuery.of(context).size.width / 2.4,
                      child: Text(
                        displayName,
                        textAlign: TextAlign.right,
                        style: AppStyles.textStyleTransactionAddress(context),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  } //Transaction Card End

  // Dummy Transaction Card
  Widget _buildDummyTransactionCard(
      String type, String amount, String address, BuildContext context) {
    String text;
    IconData icon;
    Color iconColor;
    if (type == AppLocalization.of(context).sent) {
      text = AppLocalization.of(context).sent;
      icon = AppIcons.sent;
      iconColor = StateContainer.of(context).curTheme.text60;
    } else {
      text = AppLocalization.of(context).received;
      icon = AppIcons.received;
      iconColor = StateContainer.of(context).curTheme.primary60;
    }
    return Container(
      margin: EdgeInsets.fromLTRB(14.0, 4.0, 14.0, 4.0),
      decoration: BoxDecoration(
        color: StateContainer.of(context).curTheme.backgroundDark,
        borderRadius: BorderRadius.circular(10.0),
        boxShadow: [StateContainer.of(context).curTheme.boxShadow],
      ),
      child: FlatButton(
        onPressed: () {
          return null;
        },
        highlightColor: StateContainer.of(context).curTheme.text15,
        splashColor: StateContainer.of(context).curTheme.text15,
        color: StateContainer.of(context).curTheme.backgroundDark,
        padding: EdgeInsets.all(0.0),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.0)),
        child: Center(
          child: Padding(
            padding:
                const EdgeInsets.symmetric(vertical: 14.0, horizontal: 20.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Container(
                        margin: EdgeInsets.only(right: 16.0),
                        child: Icon(icon, color: iconColor, size: 20)),
                    Container(
                      width: MediaQuery.of(context).size.width / 4,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            text,
                            textAlign: TextAlign.left,
                            style: AppStyles.textStyleTransactionType(context),
                          ),
                          RichText(
                            textAlign: TextAlign.left,
                            text: TextSpan(
                              text: '',
                              children: [
                                TextSpan(
                                  text: amount,
                                  style: AppStyles.textStyleTransactionAmount(
                                      context),
                                ),
                                TextSpan(
                                  text: " BAN",
                                  style: AppStyles.textStyleTransactionUnit(
                                      context),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Container(
                  width: MediaQuery.of(context).size.width / 2.4,
                  child: Text(
                    address,
                    textAlign: TextAlign.right,
                    style: AppStyles.textStyleTransactionAddress(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  } //Dummy Transaction Card End

  // Welcome Card
  TextSpan _getExampleHeaderSpan(BuildContext context) {
    String workingStr;
    if (StateContainer.of(context).selectedAccount == null || StateContainer.of(context).selectedAccount.index == 0) {
      workingStr = AppLocalization.of(context).exampleCardIntro;
    } else {
      workingStr = AppLocalization.of(context).newAccountIntro;
    }
    if (!workingStr.contains("BANANO")) {
      return TextSpan(
        text: workingStr,
        style: AppStyles.textStyleTransactionWelcome(context),
      );
    }
    // Colorize BANANO
    List<String> splitStr = workingStr.split("BANANO");
    if (splitStr.length != 2) {
      return TextSpan(
        text: workingStr,
        style: AppStyles.textStyleTransactionWelcome(context),
      );
    }
    return TextSpan(
      text: '',
      children: [
        TextSpan(
          text: splitStr[0],
          style: AppStyles.textStyleTransactionWelcome(context),
        ),
        TextSpan(
          text: "BANANO",
          style: AppStyles.textStyleTransactionWelcomePrimary(context),
        ),
        TextSpan(
          text: splitStr[1],
          style: AppStyles.textStyleTransactionWelcome(context),
        ),
      ],
    );
  }

  Widget _buildWelcomeTransactionCard(BuildContext context) {
    return Container(
      margin: EdgeInsets.fromLTRB(14.0, 4.0, 14.0, 4.0),
      decoration: BoxDecoration(
        color: StateContainer.of(context).curTheme.backgroundDark,
        borderRadius: BorderRadius.circular(10.0),
        boxShadow: [StateContainer.of(context).curTheme.boxShadow],
      ),
      child: IntrinsicHeight(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Container(
              width: 7.0,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(10.0),
                    bottomLeft: Radius.circular(10.0)),
                color: StateContainer.of(context).curTheme.primary,
                boxShadow: [StateContainer.of(context).curTheme.boxShadow],
              ),
            ),
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(
                    vertical: 14.0, horizontal: 15.0),
                child: RichText(
                  textAlign: TextAlign.center,
                  text: _getExampleHeaderSpan(context),
                ),
              ),
            ),
            Container(
              width: 7.0,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.only(
                    topRight: Radius.circular(10.0),
                    bottomRight: Radius.circular(10.0)),
                color: StateContainer.of(context).curTheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  } // Welcome Card End

  // Loading Transaction Card
  Widget _buildLoadingTransactionCard(
      String type, String amount, String address, BuildContext context) {
    String text;
    IconData icon;
    Color iconColor;
    if (type == "Sent") {
      text = "Senttt";
      icon = AppIcons.dotfilled;
      iconColor = StateContainer.of(context).curTheme.text20;
    } else {
      text = "Receiveddd";
      icon = AppIcons.dotfilled;
      iconColor = StateContainer.of(context).curTheme.primary20;
    }
    return Container(
      margin: EdgeInsets.fromLTRB(14.0, 4.0, 14.0, 4.0),
      decoration: BoxDecoration(
        color: StateContainer.of(context).curTheme.backgroundDark,
        borderRadius: BorderRadius.circular(10.0),
        boxShadow: [StateContainer.of(context).curTheme.boxShadow],
      ),
      child: FlatButton(
        onPressed: () {
          return null;
        },
        highlightColor: StateContainer.of(context).curTheme.text15,
        splashColor: StateContainer.of(context).curTheme.text15,
        color: StateContainer.of(context).curTheme.backgroundDark,
        padding: EdgeInsets.all(0.0),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.0)),
        child: Center(
          child: Padding(
            padding:
                const EdgeInsets.symmetric(vertical: 14.0, horizontal: 20.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    // Transaction Icon
                    Opacity(
                      opacity: _opacityAnimation.value,
                      child: Container(
                          margin: EdgeInsets.only(right: 16.0),
                          child: Icon(icon, color: iconColor, size: 20)),
                    ),
                    Container(
                      width: MediaQuery.of(context).size.width / 4,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          // Transaction Type Text
                          Container(
                            child: Stack(
                              alignment: AlignmentDirectional(-1, 0),
                              children: <Widget>[
                                Text(
                                  text,
                                  textAlign: TextAlign.left,
                                  style: TextStyle(
                                    fontFamily: "NunitoSans",
                                    fontSize: AppFontSizes.small,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.transparent,
                                  ),
                                ),
                                Opacity(
                                  opacity: _opacityAnimation.value,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: StateContainer.of(context)
                                          .curTheme
                                          .text45,
                                      borderRadius: BorderRadius.circular(100),
                                    ),
                                    child: Text(
                                      text,
                                      textAlign: TextAlign.left,
                                      style: TextStyle(
                                        fontFamily: "NunitoSans",
                                        fontSize: AppFontSizes.small - 4,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.transparent,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // Amount Text
                          Container(
                            child: Stack(
                              alignment: AlignmentDirectional(-1, 0),
                              children: <Widget>[
                                Text(
                                  amount,
                                  textAlign: TextAlign.left,
                                  style: TextStyle(
                                      fontFamily: "NunitoSans",
                                      color: Colors.transparent,
                                      fontSize: AppFontSizes.smallest,
                                      fontWeight: FontWeight.w600),
                                ),
                                Opacity(
                                  opacity: _opacityAnimation.value,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: StateContainer.of(context)
                                          .curTheme
                                          .primary20,
                                      borderRadius: BorderRadius.circular(100),
                                    ),
                                    child: Text(
                                      amount,
                                      textAlign: TextAlign.left,
                                      style: TextStyle(
                                          fontFamily: "NunitoSans",
                                          color: Colors.transparent,
                                          fontSize: AppFontSizes.smallest - 3,
                                          fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                // Address Text
                Container(
                  width: MediaQuery.of(context).size.width / 2.4,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      Container(
                        child: Stack(
                          alignment: AlignmentDirectional(1, 0),
                          children: <Widget>[
                            Text(
                              address,
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                fontSize: AppFontSizes.smallest,
                                fontFamily: 'OverpassMono',
                                fontWeight: FontWeight.w100,
                                color: Colors.transparent,
                              ),
                            ),
                            Opacity(
                              opacity: _opacityAnimation.value,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: StateContainer.of(context)
                                      .curTheme
                                      .text20,
                                  borderRadius: BorderRadius.circular(100),
                                ),
                                child: Text(
                                  address,
                                  textAlign: TextAlign.right,
                                  style: TextStyle(
                                    fontSize: AppFontSizes.smallest - 3,
                                    fontFamily: 'OverpassMono',
                                    fontWeight: FontWeight.w100,
                                    color: Colors.transparent,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  } // Loading Transaction Card End

  //Main Card
  Widget _buildMainCard(BuildContext context, _scaffoldKey) {
    return Container(
      decoration: BoxDecoration(
        color: StateContainer.of(context).curTheme.backgroundDark,
        borderRadius: BorderRadius.circular(10.0),
        boxShadow: [StateContainer.of(context).curTheme.boxShadow],
      ),
      margin: EdgeInsets.only(
          left: 14.0,
          right: 14.0,
          top: MediaQuery.of(context).size.height * 0.005),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Container(
            width: 90.0,
            height: 120,
            alignment: Alignment(-1, -1),
            child: Container(
              margin: EdgeInsets.only(top: 5, left: 5),
              height: 50,
              width: 50,
              child: FlatButton(
                  highlightColor: StateContainer.of(context).curTheme.text15,
                  splashColor: StateContainer.of(context).curTheme.text15,
                  onPressed: () {
                    _scaffoldKey.currentState.openDrawer();
                  },
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(50.0)),
                  padding: EdgeInsets.all(0.0),
                  child: Icon(AppIcons.settings,
                      color: StateContainer.of(context).curTheme.text,
                      size: 24)),
            ),
          ),
          _getBalanceWidget(context),
          Container(
            width: 90.0,
            height: 90.0,
            child: _monKey == null
                ? _monKey = FlareActor(
                    "assets/monkey_placeholder_animation.flr",
                    animation: "main",
                    fit: BoxFit.contain,
                    color: StateContainer.of(context).curTheme.primary)
                : FlatButton(
                    highlightColor: StateContainer.of(context).curTheme.text15,
                    splashColor: StateContainer.of(context).curTheme.text15,
                    child: _monkeyOverlayOpen
                        ? SizedBox()
                        : Stack(children: <Widget>[
                            Container(width: 80, height: 80, child: _largeMonkey),
                            Center(
                              child: Container(
                                width: 90,
                                height: 90,
                                color: StateContainer.of(context)
                                    .curTheme
                                    .backgroundDark,
                              ),
                            ),
                            _monKey
                          ]),
                    padding: EdgeInsets.all(0.0),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(100.0)),
                    onPressed: () {
                      if (_monkeyOverlayOpen || _largeMonkey == null) {
                        return;
                      }
                      setState(() {
                        _monkeyOverlayOpen = true;
                      });
                      Navigator.of(context).push(MonkeyOverlay(_largeMonkey));
                    }),
          ),
        ],
      ),
    );
  } //Main Card

  // Get balance display
  Widget _getBalanceWidget(BuildContext context) {
    if (StateContainer.of(context).wallet.loading) {
      // Placeholder for balance text
      return Container(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Container(
              child: Stack(
                alignment: AlignmentDirectional(0, 0),
                children: <Widget>[
                  Text(
                    "1234567",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontFamily: "NunitoSans",
                        fontSize: AppFontSizes.small,
                        fontWeight: FontWeight.w600,
                        color: Colors.transparent),
                  ),
                  Opacity(
                    opacity: _opacityAnimation.value,
                    child: Container(
                      decoration: BoxDecoration(
                        color: StateContainer.of(context).curTheme.text20,
                        borderRadius: BorderRadius.circular(100),
                      ),
                      child: Text(
                        "1234567",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontFamily: "NunitoSans",
                            fontSize: AppFontSizes.small - 3,
                            fontWeight: FontWeight.w600,
                            color: Colors.transparent),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width - 225),
              child: Stack(
                alignment: AlignmentDirectional(0, 0),
                children: <Widget>[
                  AutoSizeText(
                    "1234567",
                    style: TextStyle(
                        fontFamily: "NunitoSans",
                        fontSize: AppFontSizes.largestc,
                        fontWeight: FontWeight.w900,
                        color: Colors.transparent),
                    maxLines: 1,
                    stepGranularity: 0.1,
                    minFontSize: 1,
                  ),
                  Opacity(
                    opacity: _opacityAnimation.value,
                    child: Container(
                      decoration: BoxDecoration(
                        color: StateContainer.of(context).curTheme.primary60,
                        borderRadius: BorderRadius.circular(100),
                      ),
                      child: AutoSizeText(
                        "1234567",
                        style: TextStyle(
                            fontFamily: "NunitoSans",
                            fontSize: AppFontSizes.largestc - 8,
                            fontWeight: FontWeight.w900,
                            color: Colors.transparent),
                        maxLines: 1,
                        stepGranularity: 0.1,
                        minFontSize: 1,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              child: Stack(
                alignment: AlignmentDirectional(0, 0),
                children: <Widget>[
                  Text(
                    "1234567",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontFamily: "NunitoSans",
                        fontSize: AppFontSizes.small,
                        fontWeight: FontWeight.w600,
                        color: Colors.transparent),
                  ),
                  Opacity(
                    opacity: _opacityAnimation.value,
                    child: Container(
                      decoration: BoxDecoration(
                        color: StateContainer.of(context).curTheme.text20,
                        borderRadius: BorderRadius.circular(100),
                      ),
                      child: Text(
                        "1234567",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontFamily: "NunitoSans",
                            fontSize: AppFontSizes.small - 3,
                            fontWeight: FontWeight.w600,
                            color: Colors.transparent),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return GestureDetector(
      onTap: () {
        if (_priceConversion == PriceConversion.BTC) {
          // Cycle to NANO price
          setState(() {
            _pricesHidden = false;
            _priceConversion = PriceConversion.NANO;
          });
          SharedPrefsUtil.inst.setPriceConversion(PriceConversion.NANO);
        } else if (_priceConversion == PriceConversion.NANO) {
          // Hide prices
          setState(() {
            _pricesHidden = true;
            _priceConversion = PriceConversion.NONE;
          });
          SharedPrefsUtil.inst.setPriceConversion(PriceConversion.NONE);
        } else {
          // Cycle to BTC price
          setState(() {
            _pricesHidden = false;
            _priceConversion = PriceConversion.BTC;
          });
          SharedPrefsUtil.inst.setPriceConversion(PriceConversion.BTC);
        }
      },
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(
                StateContainer.of(context).wallet.getLocalCurrencyPrice(
                    locale: StateContainer.of(context).currencyLocale),
                textAlign: TextAlign.center,
                style: _pricesHidden
                    ? AppStyles.textStyleCurrencyAltHidden(context)
                    : AppStyles.textStyleCurrencyAlt(context)),
            Container(
              margin: EdgeInsets.only(right: 15),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Container(
                    constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width - 225),
                    child: AutoSizeText.rich(
                      TextSpan(
                        children: [
                          // Currency Icon
                          TextSpan(
                            text: "",
                            style: TextStyle(
                              fontFamily: 'AppIcons',
                              color:
                                  StateContainer.of(context).curTheme.primary,
                              fontSize: 23.0,
                            ),
                          ),
                          // Main balance text
                          TextSpan(
                            text: StateContainer.of(context)
                                .wallet
                                .getAccountBalanceDisplay(),
                            style: AppStyles.textStyleCurrency(context),
                          ),
                        ],
                      ),
                      maxLines: 1,
                      style: TextStyle(fontSize: 28.0),
                      stepGranularity: 0.1,
                      minFontSize: 1,
                    ),
                  ),
                ],
              ),
            ),
            Row(
              children: <Widget>[
                Icon(
                    _priceConversion == PriceConversion.BTC
                        ? AppIcons.btc
                        : AppIcons.nanocurrency,
                    color: _priceConversion == PriceConversion.NONE
                        ? Colors.transparent
                        : StateContainer.of(context).curTheme.text60,
                    size: 14),
                Text(
                    _priceConversion == PriceConversion.BTC
                        ? StateContainer.of(context).wallet.btcPrice
                        : StateContainer.of(context).wallet.nanoPrice,
                    textAlign: TextAlign.center,
                    style: _pricesHidden
                        ? AppStyles.textStyleCurrencyAltHidden(context)
                        : AppStyles.textStyleCurrencyAlt(context)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class TransactionDetailsSheet {
  String _hash;
  String _address;
  String _displayName;
  TransactionDetailsSheet(String hash, String address, String displayName)
      : _hash = hash,
        _address = address,
        _displayName = displayName;
  // Current state references
  bool _addressCopied = false;
  // Timer reference so we can cancel repeated events
  Timer _addressCopiedTimer;

  mainBottomSheet(BuildContext context) {
    AppSheets.showAppHeightEightSheet(
        animationDurationMs: 175,
        context: context,
        builder: (BuildContext context) {
          return StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) {
            return SafeArea(
              minimum: EdgeInsets.only(
                bottom: MediaQuery.of(context).size.height * 0.035,
              ),
              child: Container(
                width: double.infinity,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Column(
                      children: <Widget>[
                        // A stack for Copy Address and Add Contact buttons
                        Stack(
                          children: <Widget>[
                            // A row for Copy Address Button
                            Row(
                              children: <Widget>[
                                AppButton.buildAppButton(
                                    context,
                                    // Share Address Button
                                    _addressCopied
                                        ? AppButtonType.SUCCESS
                                        : AppButtonType.PRIMARY,
                                    _addressCopied
                                        ? AppLocalization.of(context)
                                            .addressCopied
                                        : AppLocalization.of(context)
                                            .copyAddress,
                                    Dimens.BUTTON_TOP_EXCEPTION_DIMENS,
                                    onPressed: () {
                                  Clipboard.setData(
                                      new ClipboardData(text: _address));
                                  setState(() {
                                    // Set copied style
                                    _addressCopied = true;
                                  });
                                  if (_addressCopiedTimer != null) {
                                    _addressCopiedTimer.cancel();
                                  }
                                  _addressCopiedTimer = new Timer(
                                      const Duration(milliseconds: 800), () {
                                    setState(() {
                                      _addressCopied = false;
                                    });
                                  });
                                }),
                              ],
                            ),
                            // A row for Add Contact Button
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: <Widget>[
                                Container(
                                  margin: EdgeInsets.only(
                                      top:
                                          Dimens.BUTTON_TOP_EXCEPTION_DIMENS[1],
                                      right: Dimens
                                          .BUTTON_TOP_EXCEPTION_DIMENS[2]),
                                  child: Container(
                                    height: 55,
                                    width: 55,
                                    // Add Contact Button
                                    child: !_displayName.startsWith("@")
                                        ? FlatButton(
                                            onPressed: () {
                                              Navigator.of(context).pop();
                                              AddContactSheet(address: _address)
                                                  .mainBottomSheet(context);
                                            },
                                            splashColor: Colors.transparent,
                                            highlightColor: Colors.transparent,
                                            shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(
                                                        100.0)),
                                            padding: EdgeInsets.symmetric(
                                                vertical: 10.0, horizontal: 10),
                                            child: Icon(AppIcons.addcontact,
                                                size: 35,
                                                color: _addressCopied
                                                    ? StateContainer.of(context)
                                                        .curTheme
                                                        .successDark
                                                    : StateContainer.of(context)
                                                        .curTheme
                                                        .backgroundDark),
                                          )
                                        : SizedBox(),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        // A row for View Details button
                        Row(
                          children: <Widget>[
                            AppButton.buildAppButton(
                                context,
                                AppButtonType.PRIMARY_OUTLINE,
                                AppLocalization.of(context).viewDetails,
                                Dimens.BUTTON_BOTTOM_DIMENS, onPressed: () {
                              Navigator.of(context).push(MaterialPageRoute(
                                  builder: (BuildContext context) {
                                return UIUtil.showBlockExplorerWebview(
                                    context, _hash);
                              }));
                            }),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          });
        });
  }
}

// monKey Overlay
class MonkeyOverlay extends ModalRoute<void> {
  var monKey;
  MonkeyOverlay(this.monKey);

  @override
  Duration get transitionDuration => Duration(milliseconds: 200);

  @override
  bool get opaque => false;

  @override
  bool get barrierDismissible => false;

  @override
  Color get barrierColor => AppColors.overlay70;

  @override
  String get barrierLabel => null;

  @override
  bool get maintainState => false;

  Future<bool> _onClosed() async {
    EventTaxiImpl.singleton().fire(MonkeyOverlayClosedEvent());
    return true;
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    // Setup position transition
    return WillPopScope(
      onWillPop: _onClosed,
      child: Material(
        type: MaterialType.transparency,
        child: SafeArea(child: _buildOverlayContent(context)),
      ),
    );
  }

  Widget _buildOverlayContent(BuildContext context) {
    return Container(
      constraints: BoxConstraints.expand(),
      child: Stack(
        children: <Widget>[
          GestureDetector(
            onTap: () {
              _onClosed();
              Navigator.pop(context);
            },
            child: Container(
              color: Colors.transparent,
              child: SizedBox.expand(),
              constraints: BoxConstraints.expand(),
            ),
          ),
          Container(
            alignment: Alignment(0, -0.3),
            child: ClipOval(
              child: Container(
                width: MediaQuery.of(context).size.width,
                height: MediaQuery.of(context).size.width,
                child: monKey,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0.42, -0.42),
        end: Offset.zero,
      ).animate(animation),
      child: ScaleTransition(
        scale: animation,
        child: FadeTransition(opacity: animation, child: child),
      ),
    );
  }
}

/// This is used so that the elevation of the container is kept and the
/// drop shadow is not clipped.
///
class _SizeTransitionNoClip extends AnimatedWidget {
  final Widget child;

  const _SizeTransitionNoClip(
      {@required Animation<double> sizeFactor, this.child})
      : super(listenable: sizeFactor);

  @override
  Widget build(BuildContext context) {
    return new Align(
      alignment: const AlignmentDirectional(-1.0, -1.0),
      widthFactor: null,
      heightFactor: (this.listenable as Animation<double>).value,
      child: child,
    );
  }
}
