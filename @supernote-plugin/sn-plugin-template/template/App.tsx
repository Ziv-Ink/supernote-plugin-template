import React, {useEffect} from 'react';
import {View} from 'react-native';
import {PluginManager} from 'sn-plugin-lib';

function App(): React.JSX.Element {
  useEffect(() => {
    const subscription = PluginManager.registerButtonListener({
      onButtonPress: () => {
        console.log('hello world');
      },
    });

    return () => {
      subscription.remove();
    };
  }, []);

  return <View />;
}

export default App;
